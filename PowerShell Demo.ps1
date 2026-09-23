$tenantId = "..."
$clientId = "..."
$clientSecret = "..."
$baseUri = "https://api.businesscentral.dynamics.com"
$url = $baseUri+"/admin/v2.6"

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

$Environments = Invoke-RestMethod -Method Get `
    -Uri $url"/applications/BusinessCentral/environments" `
    -Headers $headers

$Environments.value


$EnvironmentDetails = Invoke-RestMethod -Method Get `
    -Uri $url"/applications/BusinessCentral/environments/AardvarkLabs" `
    -Headers $headers

$InstalledApps = Invoke-RestMethod -Method Get `
    -Uri $url"/applications/BusinessCentral/environments/AardvarkLabs/apps" `
    -Headers $headers

$InstalledApps.value

$AvailableUpdates = Invoke-RestMethod -Method Get `
    -Uri $url"/applications/BusinessCentral/environments/AardvarkLabs/apps/availableUpdates" `
    -Headers $headers

$AvailableUpdates.value

$OutageDetails = Invoke-RestMethod -Method Get `
    -Uri $baseUri"/admin/v2.29/support/reportedoutages" `
    -Headers $headers

$OutageDetails.value

$UninstallRequirements = Invoke-RestMethod -Method Get `
    -Uri $baseUri"/admin/v2.29/apps/95f78464-383c-4204-8398-4123a3d9f350/uninstallRequirements" `
    -Headers $headers
    
    /apps/{appId}/uninstallRequirements