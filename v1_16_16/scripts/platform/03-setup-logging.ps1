#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose:
#   Prepare host-visible Sandbox log folders for either:
#     AMA              - Option 2, Azure Monitor Agent + DCR
#     LogsIngestionApi - Option 3, host-side Azure Monitor Logs Ingestion API
#     None             - retain logs locally only
#
# This script does not install AMA and does not store Sentinel credentials.
# Endpoint/Security platform automation owns forwarding configuration.
# =============================================================================
[CmdletBinding()]
param(
    [ValidateSet('AMA', 'LogsIngestionApi', 'None')]
    [string]$Mode = 'None',
    [string]$LogRoot = 'C:\ProgramData\AI-Sandbox\Logs'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path @(
    $LogRoot,
    (Join-Path $LogRoot 'devcontainer'),
    (Join-Path $LogRoot 'squid')
) | Out-Null

Write-Host "[OK] Host log root prepared: $LogRoot" -ForegroundColor Green
Write-Host "Set SANDBOX_LOG_ROOT=$($LogRoot.Replace('\', '/')) in the runtime .env"

switch ($Mode) {
    'AMA' {
        Write-Host 'Configure Azure Monitor Agent + DCR Custom Text Logs for devcontainer\*.log and squid\*.log. This includes audit/security, Claude/Gemini telemetry, Databricks, Tavily, Snyk, ADO, HiddenLayer and MCP event files.'
        Write-Host 'See sentinel\README.md and sentinel\dcr-ama-custom-text.example.json.'
    }
    'LogsIngestionApi' {
        Write-Host 'Configure a DCR/custom table and use scripts\monitoring\send-logs-ingestion.ps1.'
        Write-Host 'See sentinel\README.md and sentinel\dcr-logs-ingestion.example.json.'
    }
    default {
        Write-Host 'No forwarding method selected. Logs remain on the host.' -ForegroundColor Yellow
    }
}
