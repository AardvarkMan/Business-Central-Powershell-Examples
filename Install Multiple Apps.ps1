# ============================================================
# Sort Business Central .app files by dependency (ASCII only)
# ============================================================
$tenantId = "..."
$clientId = "..."
$clientSecret = "..."
$baseUri = "https://api.businesscentral.dynamics.com"
$url = $baseUri+"/admin/v2.29"

# Function for identifing if a version number is newer
function Is-NewerVersion {
    param(
        [string]$IncomingVersion,
        [string]$InstalledVersion
    )

    $vIncoming = [version]$IncomingVersion
    $vInstalled = [version]$InstalledVersion

    return ($vIncoming -gt $vInstalled)
}

# Function for identifying dependancy order by counting the visits to a given ID by other extensions
function Visit($id) {
    if ($visited[$id]) { return }
    if ($visiting[$id]) { throw "Circular dependency detected at $id" }

    $visiting[$id] = $true

    foreach ($dep in $graph[$id]) {
        if ($graph.ContainsKey($dep)) {
            Visit $dep
        }
    }

    $visiting[$id] = $false
    $visited[$id] = $true

    $null = $sorted.Add($id)
}

$body = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = "https://api.businesscentral.dynamics.com/.default"
}

$token = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
    -Body $body

$headers = @{ Authorization = "Bearer $($token.access_token)" }

# Prompt for environment name
$envName = Read-Host "Enter the environment name (e.g., Production)"

Add-Type -AssemblyName System.Windows.Forms

# Folder Picker
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = "Select the folder containing .app files"
$dialog.ShowNewFolderButton = $false
$null = $dialog.ShowDialog()

if ([string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
    Write-Host "No folder selected. Exiting."
    exit
}

$sourceFolder = $dialog.SelectedPath
Write-Host "Using source folder: $sourceFolder"

# Auto-detect 7-Zip
$SevenZipCandidates = @(
    "$env:ProgramFiles\7-Zip\7z.exe",
    "$env:ProgramFiles(x86)\7-Zip\7z.exe"
)

$SevenZip = $SevenZipCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $SevenZip) {
    Write-Host "7z.exe not found. Enter full path:"
    $SevenZip = Read-Host "Path to 7z.exe"

    if (-not (Test-Path $SevenZip)) {
        Write-Host "Invalid path. Exiting."
        exit
    }
}

Write-Host "Using 7-Zip at: $SevenZip"

# Extract metadata from each .app
$apps = @()

Get-ChildItem $sourceFolder -Filter *.app | ForEach-Object {
    $appPath = $_.FullName
    $appName = $_.Name

    $temp = "temp_extract"
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
    mkdir $temp | Out-Null

    # Extract NavxManifest.xml
    & $SevenZip e $appPath "NavxManifest.xml" "-o$temp" -y | Out-Null

    $manifestPath = Join-Path $temp "NavxManifest.xml"

    if (-not (Test-Path $manifestPath)) {
        Write-Host "$appName has no NavxManifest.xml. Skipping."
        return
    }

    [xml]$xml = Get-Content $manifestPath
    $appNode = $xml.Package.App

    $dependencyIds = @()

    if ($xml.Package.Dependencies.Dependency) {
        foreach ($dep in $xml.Package.Dependencies.Dependency) {
            $dependencyIds += $dep.Id
        }
    }

    $apps += [PSCustomObject]@{
        FileName = $appName
        Path     = $appPath
        Id       = $appNode.Id
        Name     = $appNode.Name
        Publisher= $appNode.Publisher
        Version  = $appNode.Version
        DependsOn= $dependencyIds
    }

    Remove-Item $temp -Recurse -Force
}

# Build dependency graph
$graph = @{}
$apps | ForEach-Object {
    $graph[$_.Id] = $_.DependsOn
}

# Topological Sort
$sorted = New-Object System.Collections.ArrayList
$visited = @{}
$visiting = @{}

foreach ($app in $apps) {
    Visit $app.Id
}

# Output sorted list
Write-Host ""
Write-Host "============================================"
Write-Host "Retrieving Currently Installed Apps"
Write-Host "============================================"

$InstalledApps = Invoke-RestMethod -Method Get `
    -Uri $url"/applications/BusinessCentral/environments/$envName/apps" `
    -Headers $headers

Write-Host ""
Write-Host "============================================"
Write-Host "Dependency-Sorted Install Order"
Write-Host "============================================"

foreach ($id in $sorted) {
    $app = $apps | Where-Object { $_.Id -eq $id }
    Write-Host $app.FileName

    $appFilePath = $app.Path
    Write-Host "Selected APP file: $appFilePath"

    # Validating that the App to be installed is a newer version than the currently installed version
    $Installed = $installedApps.value | Where-Object { $_.id -eq $app.id }
    if ($Installed) {
        if (Is-NewerVersion -IncomingVersion $app.Version -InstalledVersion $Installed.version) {
            Write-Host "Installing newer version of $($app.Name)"
        }
        else {
            Write-Host "Skipping $($Installed.Name). Installed version ($($Installed.version)) is newer or equal."
            break
        }
    }

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Uploading APP to Business Central"
    Write-Host "============================================"

    # JSON body required by pteInstall
    $jsonBody = @{
        deploymentSchedule = "Immediate"
        syncMode = "Add"
        languageId = "en-US"
        acceptIsvEula = $true
        installOrUpdateNeededDependencies = $false
    } | ConvertTo-Json -Depth 5

    $boundary = [System.Guid]::NewGuid().ToString()
    $lf = "`r`n"

    $ms = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.StreamWriter($ms)

    # extensionFile (binary)
    $writer.Write("--$boundary$lf")
    $writer.Write("Content-Disposition: form-data; name=`"extensionFile`"; filename=`"$(Split-Path $appFilePath -Leaf)`"$lf")
    $writer.Write("Content-Type: application/octet-stream$lf$lf")
    $writer.Flush()
    $ms.Write([System.IO.File]::ReadAllBytes($appFilePath), 0, (Get-Item $appFilePath).Length)
    $writer.Write($lf)

    # deploymentSchedule
    $writer.Write("--$boundary$lf")
    $writer.Write("Content-Disposition: form-data; name=`"deploymentSchedule`"$lf$lf")
    $writer.Write("Immediate$lf")

    # syncMode
    $writer.Write("--$boundary$lf")
    $writer.Write("Content-Disposition: form-data; name=`"syncMode`"$lf$lf")
    $writer.Write("Add$lf")

    # languageId
    $writer.Write("--$boundary$lf")
    $writer.Write("Content-Disposition: form-data; name=`"languageId`"$lf$lf")
    $writer.Write("en-US$lf")

    # acceptIsvEula
    $writer.Write("--$boundary$lf")
    $writer.Write("Content-Disposition: form-data; name=`"acceptIsvEula`"$lf$lf")
    $writer.Write("true$lf")

    # installOrUpdateNeededDependencies
    $writer.Write("--$boundary$lf")
    $writer.Write("Content-Disposition: form-data; name=`"installOrUpdateNeededDependencies`"$lf$lf")
    $writer.Write("false$lf")

    # closing boundary
    $writer.Write("--$boundary--$lf")
    $writer.Flush()

    $ms.Position = 0

    $Results = Invoke-RestMethod `
        -Uri "$url/applications/BusinessCentral/environments/$envName/apps/pteInstall" `
        -Method Post `
        -Headers $headers `
        -ContentType "multipart/form-data; boundary=$boundary" `
        -Body $ms

    $AppID = $Results.appId

    $InstallSuccessful = $true

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Monitoring Install Status"
    Write-Host "============================================"

    while ($true) {

        $status = Invoke-RestMethod -Method Get `
            -Uri "$url/applications/BusinessCentral/environments/$envName/apps/$AppId/operations" `
            -Headers $headers

        # Get the most recent operation
        $op = $status.value | Sort-Object createdOn -Descending | Select-Object -First 1

        Write-Host "Operation $($op.id): $($op.status)"

        if ($op.status -eq "Succeeded") {
            Write-Host "App install/update succeeded."
            break   # <-- breaks the Monitor WHILE
        }

        if ($op.status -eq "Failed") {
            Write-Host "App install/update failed."
            Write-Host "Error: $($op.errorMessage)"
            $InstallSuccessful = $false
            break   # <-- breaks the Monitor WHILE
        }

        if ($op.status -eq "Canceled") {
            Write-Host "Operation was canceled."
            $InstallSuccessful = $false
            break   # <-- breaks the Monitor WHILE
        }

        Start-Sleep -Seconds 15
    }

    if ($InstallSuccessful -eq $false) {
        break   # <-- breaks the Install ForEach
    }
}