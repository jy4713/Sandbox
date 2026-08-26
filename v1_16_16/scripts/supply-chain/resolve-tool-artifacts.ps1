#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Resolves SHA-256 hashes/immutable commits for downloaded build artifacts and optionally writes .build.env.
# Admin maintenance: If a new application is downloaded outside a package manager, add its URL/hash resolution here and validate the hash in the Dockerfile.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
<#
.SYNOPSIS
  ADMIN side, supply-chain pinning (step 2 of 2): resolve SHA-256 of all
  downloaded build artifacts and pin ucode to an immutable commit.
  Windows equivalent of resolve-tool-artifacts.sh.

.DESCRIPTION
  Resolves the exact SHA-256 of every tool artifact downloaded at image
  build time, and pins the Databricks ucode repository to the current
  immutable commit of refs/heads/main. Together with
  resolve-base-digests.ps1 (which pins the base IMAGE digests) this makes
  every external input to the docker builds reproducible and auditable.

  Artifacts resolved (URLs are read from .build.env):
    AWSCLI_URL            -> AWSCLI_SHA256
    DATABRICKS_CLI_URL    -> DATABRICKS_CLI_SHA256
    SSG_URL               -> SSG_SHA256   (ComplianceAsCode data stream,
                           also consumed by build-hardened-base.ps1 and
                           assess-cis-l1.ps1)
    GCM_VERSION           -> GCM_SHA256   (Git Credential Manager .deb)
    ucode git repo        -> UCODE_GIT_REF (40-hex commit of main)

  Downloads are HTTPS-only. Without -Write the script only PRINTS the
  resolved values; with -Write it updates .build.env in place
  (preserving all other lines).

  Run order (admin, once per release / whenever a tool version changes):
    1. cp .build.env.example .build.env   (fill versions + URLs)
    2. scripts\supply-chain\resolve-base-digests.ps1 -Write
    3. scripts\supply-chain\resolve-tool-artifacts.ps1 -Write   <-- this
    4. scripts\hardening\build-hardened-base.ps1 -SandboxType <poc|production>

.PARAMETER Write
  Persist the resolved values into .build.env instead of only printing.

.EXAMPLE
  pwsh -NoProfile -File scripts\supply-chain\resolve-tool-artifacts.ps1 -Write
#>
[CmdletBinding()]
param([switch]$Write, [switch]$UcodeOnly)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$EnvFile = if ($env:BUILD_ENV_FILE) { $env:BUILD_ENV_FILE } else { Join-Path $Root '.build.env' }
if (-not (Test-Path $EnvFile)) { throw "$EnvFile not found. Copy .build.env.example to .build.env first." }

$Values = @{}
Get-Content $EnvFile -Encoding UTF8 | ForEach-Object {
    $line=$_.Trim(); if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $i=$line.IndexOf('='); $Values[$line.Substring(0,$i).Trim()]=$line.Substring($i+1).Trim()
    }
}
function Get-UrlHash([string]$Url,[string]$Label) {
    if ($Url -notmatch '^https://') { throw "$Label URL must use https" }
    $tmp=Join-Path $env:TEMP ("ai-sandbox-"+[guid]::NewGuid().ToString('N'))
    try { Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing; return (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant() }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function Set-EnvValue([string]$Key,[string]$Value) {
    $lines=Get-Content $EnvFile -Encoding UTF8
    $found=$false
    $out=foreach($line in $lines) {
        if ($line -match ('^'+[regex]::Escape($Key)+'=')) { $found=$true; "$Key=$Value" } else { $line }
    }
    if (-not $found) { $out += "$Key=$Value" }
    [IO.File]::WriteAllLines($EnvFile,$out,[Text.UTF8Encoding]::new($false))
}

$AwsHash=''
$DbHash=''
$SsgHash=''
if (-not $UcodeOnly) {
    $AwsHash=Get-UrlHash $Values['AWSCLI_URL'] 'AWS CLI'
    $DbHash=Get-UrlHash $Values['DATABRICKS_CLI_URL'] 'Databricks CLI'
    $SsgHash=Get-UrlHash $Values['SSG_URL'] 'ComplianceAsCode'
}
$UcodeLine = (& git ls-remote https://github.com/databricks/ucode.git refs/heads/main | Select-Object -First 1)
$UcodeRef = ($UcodeLine -split '\s+')[0]
if ($UcodeRef -notmatch '^[0-9a-fA-F]{40}$') { throw 'Could not resolve ucode main commit' }

$GcmHash=''
if (-not $UcodeOnly -and $Values['GCM_VERSION']) {
    $v=$Values['GCM_VERSION']
    $GcmHash=Get-UrlHash "https://github.com/git-ecosystem/git-credential-manager/releases/download/v$v/gcm-linux_amd64.$v.deb" 'Git Credential Manager'
}

if (-not $UcodeOnly) {
    Write-Host "AWSCLI_SHA256=$AwsHash"
    Write-Host "DATABRICKS_CLI_SHA256=$DbHash"
    Write-Host "SSG_SHA256=$SsgHash"
}
Write-Host "UCODE_GIT_REF=$UcodeRef"
if ($GcmHash) { Write-Host "GCM_SHA256=$GcmHash" }

if ($Write) {
    if (-not $UcodeOnly) {
        Set-EnvValue AWSCLI_SHA256 $AwsHash
        Set-EnvValue DATABRICKS_CLI_SHA256 $DbHash
        Set-EnvValue SSG_SHA256 $SsgHash
    }
    Set-EnvValue UCODE_GIT_REF $UcodeRef
    if ($GcmHash) { Set-EnvValue GCM_SHA256 $GcmHash }
    Write-Host "[OK] Updated $EnvFile" -ForegroundColor Green
} else { Write-Host "Re-run with -Write to update $EnvFile" -ForegroundColor Yellow }
