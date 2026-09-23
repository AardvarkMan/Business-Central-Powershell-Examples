$tenantId = "..."
$clientId = "..."
$clientSecret = "..."
$baseUri = "https://api.businesscentral.dynamics.com"
$url = $baseUri+"/admin/v2.29"

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

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = "Business Central App (*.app)|*.app"
$dialog.Title = "Select a Business Central .app file"

$null = $dialog.ShowDialog()

if ($dialog.FileName -eq "") {
    Write-Host "❌ No file selected. Exiting."
    return
}

$appFilePath = $dialog.FileName
Write-Host "Selected APP file: $appFilePath"

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

while ($true) {

    $status = Invoke-RestMethod -Method Get `
        -Uri "$url/applications/BusinessCentral/environments/$envName/apps/$AppId/operations" `
        -Headers $headers

    # Get the most recent operation
    $op = $status.value | Sort-Object createdOn -Descending | Select-Object -First 1

    Write-Host "Operation $($op.id): $($op.status)"

    if ($op.status -eq "Succeeded") {
        Write-Host "✔ App install/update succeeded."
        break   # <-- breaks the WHILE
    }

    if ($op.status -eq "Failed") {
        Write-Host "❌ App install/update failed."
        Write-Host "Error: $($op.errorMessage)"
        break   # <-- breaks the WHILE
    }

    if ($op.status -eq "Canceled") {
        Write-Host "⚠ Operation was canceled."
        break   # <-- breaks the WHILE
    }

    Start-Sleep -Seconds 15
}

$uninstallReqs = Invoke-RestMethod -Method Get `
        -Uri "$url/applications/BusinessCentral/environments/$envName/apps/$AppId/uninstallRequirements" `
        -Headers $headers

$uninstallReqs.requirements

$body = @{
    useEnvironmentUpdateWindow = $false
    uninstallDependents         = $false
    deleteData                  = $true
} | ConvertTo-Json

$operation = Invoke-RestMethod -Method Post `
    -Uri "$url/applications/BusinessCentral/environments/$envName/apps/$appId/uninstall" `
    -Headers $headers `
    -ContentType "application/json" `
    -Body $body

Write-Host "Uninstall started. Operation ID: $($operation.id)"


# --- 3️⃣ Poll until uninstall completes ---
while ($true) {

    $status = Invoke-RestMethod -Method Get `
        -Uri "$url/applications/BusinessCentral/environments/$envName/apps/$appId/operations" `
        -Headers $headers

    if (-not $status.value) {
        Write-Host "Waiting for operation to appear..."
        Start-Sleep -Seconds 5
        continue
    }

    $op = $status.value | Sort-Object createdOn -Descending | Select-Object -First 1

    Write-Host "Operation $($op.id): $($op.status)"

    if ($op.status -eq "Succeeded") {
        Write-Host "✔ App uninstall succeeded."
        break
    }

    if ($op.status -eq "Failed") {
        Write-Host "❌ App uninstall failed."
        Write-Host "Error: $($op.errorMessage)"
        break
    }

    if ($op.status -eq "Canceled") {
        Write-Host "⚠ Uninstall was canceled."
        break
    }

    Start-Sleep -Seconds 5
}