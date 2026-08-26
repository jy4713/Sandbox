#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Host-side PowerShell launcher for Azure DevOps authentication checks inside the devcontainer.
# Admin maintenance: Keep paired behavior aligned with ado-auth-setup.sh. Application installation does not belong here.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/validation.
# Optional Admin guide (SLIM package): docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# ado-auth-setup.ps1 — Host-side launcher for current ADO auth status/help
#
# This launcher executes the Admin-managed Bash helper inside the DevContainer.
# It does not configure or persist PAT/SP credentials. Runtime credentials are
# injected per command by run-with-ssm-secrets.
# =============================================================================
param([ValidateSet("check","help")][string]$Mode = "check")

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot
$SvcDir  = if (Test-Path (Join-Path $Root "poc\docker-compose.yml")) { "poc" } else { "ecr" }

Set-Location (Join-Path $Root $SvcDir)
Write-Host "Running ado-auth-setup $Mode inside container..." -ForegroundColor Cyan
docker compose exec devcontainer bash /usr/local/bin/ado-auth-setup $Mode
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
