#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose:
#   Option 3 reference host sender for Azure Monitor Logs Ingestion API.
#
# Behavior:
#   - Reads new non-empty lines from *.log files under the host log root.
#   - Sends JSON arrays matching the configured DCR input stream.
#   - Stores only line-count checkpoints in a local state file.
#   - Does not run inside either Sandbox container.
#
# Production note:
#   This is a reference sender. Prefer the organization's approved managed
#   host identity/credential and service scheduling mechanism. Do not embed
#   Entra client secrets in the Developer package.
# =============================================================================
[CmdletBinding()]
param(
    [string]$LogRoot = 'C:\ProgramData\AI-Sandbox\Logs',
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $true)][string]$DcrImmutableId,
    [string]$StreamName = 'Custom-AISandboxHostLogs',
    [Parameter(Mandatory = $true)][string]$TenantId,
    [Parameter(Mandatory = $true)][string]$ClientId,
    [string]$ClientSecret = $env:AZURE_CLIENT_SECRET,
    [string]$ClientSecretSsmParameter,
    [string]$AwsProfile = 'sandbox',
    [string]$AwsRegion = 'eu-west-2',
    [string]$StateFile,
    [ValidateRange(1, 1000)][int]$BatchSize = 200
)

$ErrorActionPreference = 'Stop'

# Azure Monitor requires modern HTTPS. The package standard is PowerShell 7.4+;
# keep TLS 1.2 explicitly enabled for compatibility with the endpoint/host stack.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $LogRoot)) {
    throw "Log root does not exist: $LogRoot"
}
if (-not $StateFile) {
    $StateFile = Join-Path $LogRoot '.logs-ingestion-state.json'
}

# Optional POC helper: obtain the Entra application secret from AWS SSM on the
# Windows host. Production should use the client's approved credential model.
if (-not $ClientSecret -and $ClientSecretSsmParameter) {
    $ClientSecret = & aws ssm get-parameter `
        --name $ClientSecretSsmParameter `
        --with-decryption `
        --profile $AwsProfile `
        --region $AwsRegion `
        --query Parameter.Value `
        --output text
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to fetch Azure Monitor client secret from AWS SSM'
    }
    $ClientSecret = $ClientSecret.Trim()
}
if (-not $ClientSecret) {
    throw 'Provide AZURE_CLIENT_SECRET, -ClientSecret, or -ClientSecretSsmParameter'
}

# Obtain a bearer token for the Azure Monitor public-cloud audience.
$TokenResponse = Invoke-RestMethod `
    -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        client_id     = $ClientId
        scope         = 'https://monitor.azure.com/.default'
        client_secret = $ClientSecret
        grant_type    = 'client_credentials'
    }

if (-not $TokenResponse.access_token) {
    throw 'Microsoft Entra token response did not contain an access token'
}

$Headers = @{
    Authorization  = "Bearer $($TokenResponse.access_token)"
    'Content-Type' = 'application/json'
}
$Uri = "$($Endpoint.TrimEnd('/'))/dataCollectionRules/$DcrImmutableId/streams/$StreamName?api-version=2023-01-01"

# Load file checkpoints. A missing/corrupt state file means start from line 0.
$State = @{}
if (Test-Path $StateFile) {
    try {
        $Saved = Get-Content $StateFile -Raw | ConvertFrom-Json
        $Saved.psobject.Properties | ForEach-Object {
            $State[$_.Name] = [int64]$_.Value
        }
    }
    catch {
        Write-Warning "Ignoring invalid state file: $StateFile"
        $State = @{}
    }
}

$TotalSent = 0
foreach ($File in Get-ChildItem $LogRoot -Recurse -File -Filter '*.log') {
    $Lines = @(Get-Content $File.FullName)
    $Start = if ($State.ContainsKey($File.FullName)) {
        [int64]$State[$File.FullName]
    }
    else {
        0
    }

    # Treat truncation/rotation as a new file.
    if ($Start -gt $Lines.Count) { $Start = 0 }

    $Records = @()
    for ($Index = $Start; $Index -lt $Lines.Count; $Index++) {
        if (-not [string]::IsNullOrWhiteSpace($Lines[$Index])) {
            $Records += [ordered]@{
                Time    = (Get-Date).ToUniversalTime().ToString('o')
                RawData = $Lines[$Index]
            }
        }
    }

    if ($Records.Count -gt 0) {
        for ($Offset = 0; $Offset -lt $Records.Count; $Offset += $BatchSize) {
            $Last = [Math]::Min($Offset + $BatchSize - 1, $Records.Count - 1)
            $Batch = @($Records[$Offset..$Last])
            $Body = ConvertTo-Json -InputObject $Batch -Compress -Depth 4
            Invoke-RestMethod -Method Post -Uri $Uri -Headers $Headers -Body $Body | Out-Null
        }
        Write-Host "[OK] Sent $($Records.Count) line(s) from $($File.FullName)" -ForegroundColor Green
        $TotalSent += $Records.Count
    }

    $State[$File.FullName] = $Lines.Count
}

$State | ConvertTo-Json -Depth 3 | Set-Content $StateFile -Encoding UTF8
$ClientSecret = $null
$TokenResponse = $null
Write-Host "[OK] Logs Ingestion API run complete. Records sent: $TotalSent" -ForegroundColor Green
