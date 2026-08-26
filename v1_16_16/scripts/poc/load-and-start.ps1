#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose:
#   Developer POC launcher for the approved DevContainer + Squid TAR bundle.
#
# Maintenance boundary:
#   Keep the required bundle files, runtime-policy validation, image ID checks,
#   and the paired Bash launcher synchronized with scripts/poc/build-and-export.*.
#
# Logging:
#   This launcher creates host-visible DevContainer and Squid log directories.
#   It does not start or authenticate a monitoring/forwarding container.
# =============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Images = Join-Path $Root 'poc\images'
$EnvFile = Join-Path $Root '.env'
$Compose = Join-Path $Root 'poc\docker-compose.yml'

$Required = @(
    'sandbox-devcontainer.tar',
    'sandbox-squid.tar',
    'image-manifest.json',
    'image-manifest.env',
    'runtime-policy.sha256',
    'SHA256SUMS'
)

foreach ($FileName in $Required) {
    $Path = Join-Path $Images $FileName
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        throw "Missing or empty POC bundle file: $Path"
    }
}

if (-not (Test-Path $EnvFile)) {
    Copy-Item (Join-Path $Root '.env.example') $EnvFile
    Write-Host "Created $EnvFile. Configure runtime values and rerun. Protect .env if AWS static credentials are used." -ForegroundColor Yellow
    exit 2
}

function Read-KeyValueFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Map = @{}
    Get-Content $Path | ForEach-Object {
        $Line = $_.TrimEnd("`r")
        if ($Line -and -not $Line.TrimStart().StartsWith('#')) {
            $Index = $Line.IndexOf('=')
            if ($Index -gt 0) {
                $Map[$Line.Substring(0, $Index).Trim()] = $Line.Substring($Index + 1)
            }
        }
    }
    return $Map
}

function Test-ConfiguredValue {
    param([string]$Value)
    return (
        -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -notmatch '[<>]' -and
        $Value -notlike '*REPLACE_*' -and
        $Value -ne 'yourname'
    )
}

$Runtime = Read-KeyValueFile -Path $EnvFile
if (-not (Test-ConfiguredValue $Runtime['DEVELOPER_ID'])) {
    throw 'DEVELOPER_ID is missing or still a placeholder in .env'
}
if ($Runtime['DATABRICKS_HOST'] -and $Runtime['DATABRICKS_HOST'] -notmatch '^https://') {
    throw 'DATABRICKS_HOST must use https:// when configured'
}

$HasAccessKey = Test-ConfiguredValue $Runtime['AWS_ACCESS_KEY_ID']
$HasSecretKey = Test-ConfiguredValue $Runtime['AWS_SECRET_ACCESS_KEY']
$HasSessionToken = Test-ConfiguredValue $Runtime['AWS_SESSION_TOKEN']
if ($HasAccessKey -xor $HasSecretKey) {
    throw 'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be configured together. Partial static credentials do not fall back to SSO.'
}
if ($HasSessionToken -and -not ($HasAccessKey -and $HasSecretKey)) {
    throw 'AWS_SESSION_TOKEN requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.'
}
if ($HasAccessKey -and $HasSecretKey) {
    $env:AWS_ACCESS_KEY_ID = $Runtime['AWS_ACCESS_KEY_ID']
    $env:AWS_SECRET_ACCESS_KEY = $Runtime['AWS_SECRET_ACCESS_KEY']
    if ($HasSessionToken) { $env:AWS_SESSION_TOKEN = $Runtime['AWS_SESSION_TOKEN'] } else { Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue }
    Write-Host 'AWS authentication mode: static environment credentials (SSO values are not required).' -ForegroundColor Cyan
}
else {
    Remove-Item Env:AWS_ACCESS_KEY_ID,Env:AWS_SECRET_ACCESS_KEY,Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
    foreach ($Key in @('SANDBOX_AWS_PROFILE','AWS_REGION','AWS_SSO_SESSION','AWS_SSO_START_URL','AWS_SSO_REGION','AWS_SSO_ACCOUNT_ID','AWS_SSO_ROLE_NAME')) {
        if (-not (Test-ConfiguredValue $Runtime[$Key])) {
            throw "$Key is missing or still a placeholder in .env. No static AWS key pair is configured, so IAM Identity Center (SSO) fallback values are required."
        }
    }
    if ($Runtime['AWS_SSO_START_URL'] -notmatch '^https://') { throw 'AWS_SSO_START_URL must use https://' }
    if ($Runtime['AWS_SSO_ACCOUNT_ID'] -notmatch '^[0-9]{12}$') { throw 'AWS_SSO_ACCOUNT_ID must be a 12-digit AWS account ID' }
    Write-Host 'AWS authentication mode: IAM Identity Center (SSO) fallback.' -ForegroundColor Cyan
}

# Resolve the host log directory. This is a host bind mount, not a container
# monitoring service. A Windows 365 Admin may set SANDBOX_LOG_ROOT to an
# Admin-managed path such as C:/ProgramData/AI-Sandbox/Logs.
$LogRoot = $Runtime['SANDBOX_LOG_ROOT']
if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path $Root 'logs'
}
elseif (-not [IO.Path]::IsPathRooted($LogRoot)) {
    $LogRoot = Join-Path $Root $LogRoot
}
$LogRoot = [IO.Path]::GetFullPath($LogRoot)
New-Item -ItemType Directory -Force -Path @(
    (Join-Path $LogRoot 'devcontainer'),
    (Join-Path $LogRoot 'squid')
) | Out-Null
$env:SANDBOX_LOG_ROOT = $LogRoot
Write-Host "Host log root: $LogRoot" -ForegroundColor Cyan

Write-Host '[1/5] Verifying bundle hashes...' -ForegroundColor Yellow
$ImagesBase = [IO.Path]::GetFullPath($Images) + [IO.Path]::DirectorySeparatorChar
Get-Content (Join-Path $Images 'SHA256SUMS') | ForEach-Object {
    if ($_ -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
        throw "Invalid SHA256SUMS line: $_"
    }
    $Expected = $matches[1].ToLowerInvariant()
    $Relative = $matches[2].Trim()
    if ($Relative.StartsWith('./')) { $Relative = $Relative.Substring(2) }
    $Path = [IO.Path]::GetFullPath((Join-Path $Images ($Relative -replace '/', '\')))
    if (-not $Path.StartsWith($ImagesBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe hash path: $Relative"
    }
    $Actual = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "SHA256 mismatch: $Relative" }
}

Write-Host '[2/5] Verifying Admin runtime policy...' -ForegroundColor Yellow
$RootBase = [IO.Path]::GetFullPath($Root) + [IO.Path]::DirectorySeparatorChar
Get-Content (Join-Path $Images 'runtime-policy.sha256') | ForEach-Object {
    if ($_ -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
        throw "Invalid runtime-policy line: $_"
    }
    $Expected = $matches[1].ToLowerInvariant()
    $Relative = $matches[2].Trim()
    $Path = [IO.Path]::GetFullPath((Join-Path $Root ($Relative -replace '/', '\')))
    if (-not $Path.StartsWith($RootBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe policy path: $Relative"
    }
    $Actual = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "Runtime policy mismatch: $Relative" }
}

Write-Host '[3/5] Loading approved images...' -ForegroundColor Yellow
foreach ($FileName in @('sandbox-devcontainer.tar', 'sandbox-squid.tar')) {
    & docker load -i (Join-Path $Images $FileName) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker load failed: $FileName" }
}

$Manifest = Read-KeyValueFile -Path (Join-Path $Images 'image-manifest.env')
foreach ($Key in @('DEVCONTAINER_TAG', 'DEVCONTAINER_ID', 'SQUID_TAG', 'SQUID_ID')) {
    if (-not $Manifest[$Key]) { throw "Manifest missing $Key" }
}

function Confirm-ImageId {
    param([string]$Label, [string]$Tag, [string]$ExpectedId)
    $ActualId = (& docker image inspect $Tag --format '{{.Id}}' 2>$null).Trim()
    if ($ActualId -ne $ExpectedId) { throw "$Label image ID mismatch" }
    Write-Host "  [OK] $Label $ActualId" -ForegroundColor Green
}

Write-Host '[4/5] Verifying loaded image IDs...' -ForegroundColor Yellow
Confirm-ImageId -Label 'devcontainer' -Tag $Manifest.DEVCONTAINER_TAG -ExpectedId $Manifest.DEVCONTAINER_ID
Confirm-ImageId -Label 'squid' -Tag $Manifest.SQUID_TAG -ExpectedId $Manifest.SQUID_ID

Write-Host '[5/5] Starting sandbox...' -ForegroundColor Yellow
& docker compose --env-file $EnvFile -f $Compose config | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'docker compose config failed' }
& docker compose --env-file $EnvFile -f $Compose up -d --force-recreate
if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed' }

Write-Host '[OK] Sandbox started.' -ForegroundColor Green
Write-Host "[OK] Host logs: $LogRoot" -ForegroundColor Green
