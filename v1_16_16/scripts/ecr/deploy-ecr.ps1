#Requires -Version 7.4
#Requires -RunAsAdministrator
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose:
#   One-time/Admin provisioning of the Production Developer runtime on a
#   Windows 365 VM. This script does NOT build or push ECR images.
#
# Image lifecycle:
#   The Developer pull-and-start launcher fetches the current approved manifest
#   from SSM. Image-only releases therefore do not require this script to rerun.
#
# Logging:
#   Prepares a protected host log root for Option 2 (AMA) or Option 3
#   (Logs Ingestion API). No monitoring container is deployed.
# =============================================================================
[CmdletBinding()]
param(
    [string]$Target = 'C:\ai-sandbox',
    [string]$HostLogRoot = 'C:\ProgramData\AI-Sandbox\Logs'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Write-Host '=== AI Sandbox Production Runtime Provisioning ===' -ForegroundColor Cyan

$Directories = @(
    $Target,
    (Join-Path $Target '.devcontainer'),
    (Join-Path $Target 'scripts\ecr'),
    (Join-Path $Target 'workspace'),
    (Join-Path $Target 'monitoring'),
    $HostLogRoot,
    (Join-Path $HostLogRoot 'devcontainer'),
    (Join-Path $HostLogRoot 'squid')
)
New-Item -ItemType Directory -Force -Path $Directories | Out-Null

# Copy only runtime/provisioning artifacts. Admin image-build source remains in
# the Admin package and is not copied to the Developer runtime directory.
Copy-Item (Join-Path $Root 'ecr\docker-compose.yml') (Join-Path $Target 'docker-compose.yml') -Force
Copy-Item (Join-Path $Root 'templates\developer\devcontainer-production.json') (Join-Path $Target '.devcontainer\devcontainer.json') -Force
Copy-Item (Join-Path $Root 'scripts\ecr\pull-and-start.ps1') (Join-Path $Target 'scripts\ecr\pull-and-start.ps1') -Force
Copy-Item (Join-Path $Root 'scripts\ecr\pull-and-start.sh') (Join-Path $Target 'scripts\ecr\pull-and-start.sh') -Force

# Host monitoring reference utilities are Admin-managed. They are copied to a
# separate runtime subdirectory and are not executed by the Developer launcher.
Copy-Item (Join-Path $Root 'scripts\monitoring\verify-host-log-export.ps1') (Join-Path $Target 'monitoring\verify-host-log-export.ps1') -Force
Copy-Item (Join-Path $Root 'scripts\monitoring\send-logs-ingestion.ps1') (Join-Path $Target 'monitoring\send-logs-ingestion.ps1') -Force

$EnvText = Get-Content (Join-Path $Root 'templates\developer\env.example') -Raw
$EnvText = $EnvText -replace '(?m)^SANDBOX_LOG_ROOT=.*$', ('SANDBOX_LOG_ROOT=' + $HostLogRoot.Replace('\', '/'))
if ($env:ECR_REGISTRY) {
    $EnvText = $EnvText -replace '(?m)^ECR_REGISTRY=.*$', ('ECR_REGISTRY=' + $env:ECR_REGISTRY)
}
[IO.File]::WriteAllText((Join-Path $Target '.env.example'), $EnvText, [Text.UTF8Encoding]::new($false))

# Runtime definitions and launchers are read-only to standard Users. The exact
# endpoint ACL model can be tightened further by Intune/GPO for the client.
$ProtectedFiles = @(
    'docker-compose.yml',
    '.env.example',
    '.devcontainer\devcontainer.json',
    'scripts\ecr\pull-and-start.ps1',
    'scripts\ecr\pull-and-start.sh',
    'monitoring\verify-host-log-export.ps1',
    'monitoring\send-logs-ingestion.ps1'
)
foreach ($Relative in $ProtectedFiles) {
    & icacls (Join-Path $Target $Relative) `
        /inheritance:r `
        /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' '*S-1-5-32-545:(R)' | Out-Null
}

Write-Host "[OK] Runtime provisioned at $Target" -ForegroundColor Green
Write-Host "[OK] Host log root prepared at $HostLogRoot" -ForegroundColor Green
Write-Host 'Developer: copy .env.example to .env, authenticate AWS, then run scripts\ecr\pull-and-start.ps1.'
Write-Host 'Security/Endpoint Admin: configure AMA/DCR or the host Logs Ingestion API sender separately.'
