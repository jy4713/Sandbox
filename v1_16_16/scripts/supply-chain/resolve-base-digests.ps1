#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Resolves immutable digests for external base images and optionally writes them into .build.env.
# Admin maintenance: Add another base image here only if a new Docker build stage depends on a separately maintained upstream image.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# resolve-base-digests.ps1 — Resolve current digests for all base images
#
# Usage:
#   .\scripts\supply-chain\resolve-base-digests.ps1            # print only
#   .\scripts\supply-chain\resolve-base-digests.ps1 -Write     # update .build.env
#
# Requires: Docker Desktop running, docker buildx, internet access
# =============================================================================
[CmdletBinding()]
param(
    [switch]$Write,
    [string]$UbuntuRef    = 'ubuntu:24.04',
    [string]$NodeRef      = 'node:20-bookworm-slim'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error 'docker not found in PATH. Start Docker Desktop and reopen PowerShell.'
}

docker buildx version 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error 'docker buildx not available. Update Docker Desktop.'
}

function Resolve-Digest([string]$Reference) {
    $digest = docker buildx imagetools inspect $Reference --format '{{json .Manifest.Digest}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $digest) {
        throw "Cannot resolve $Reference — check network and Docker Desktop"
    }
    return $digest.Trim().Trim('"')
}

Write-Host 'Resolving image digests...' -ForegroundColor Cyan
Write-Host "  ubuntu    -> $UbuntuRef"
Write-Host "  node      -> $NodeRef"
Write-Host ''

$UbuntuDigest = Resolve-Digest $UbuntuRef
$NodeDigest   = Resolve-Digest $NodeRef

$Resolved = [ordered]@{
    BASE_IMAGE            = "$UbuntuRef@$UbuntuDigest"
    SQUID_BASE_IMAGE      = "$UbuntuRef@$UbuntuDigest"
    NODE_IMAGE            = "$NodeRef@$NodeDigest"
}

if ($Write) {
    $EnvFile = Join-Path $Root '.build.env'
    if (-not (Test-Path $EnvFile)) {
        Write-Error @"
.build.env not found at $EnvFile

Fix:  Copy-Item .build.env.example .build.env
"@
    }

    $Lines = Get-Content -Path $EnvFile -Encoding UTF8
    foreach ($key in $Resolved.Keys) {
        $value   = $Resolved[$key]
        $pattern = "^$([regex]::Escape($key))="
        if ($Lines -match $pattern) {
            $Lines = $Lines | ForEach-Object {
                if ($_ -match $pattern) { "$key=$value" } else { $_ }
            }
        } else {
            $Lines += "$key=$value"
        }
        Write-Host "  [written] $key" -ForegroundColor Green
    }
    Set-Content -Path $EnvFile -Value $Lines -Encoding UTF8
    Write-Host ''
    Write-Host "Digests written to $EnvFile" -ForegroundColor Green
} else {
    foreach ($key in $Resolved.Keys) {
        Write-Output "$key=$($Resolved[$key])"
    }
    Write-Host ''
    Write-Host 'To write these into .build.env:' -ForegroundColor Yellow
    Write-Host '  .\scripts\supply-chain\resolve-base-digests.ps1 -Write'
}
