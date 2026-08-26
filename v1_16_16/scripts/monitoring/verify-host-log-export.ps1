#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Verify DevContainer -> Windows host log export, Claude redaction, and
#          structured application audit files for approved integrations.
# =============================================================================
[CmdletBinding()]
param(
    [string]$ComposeFile,
    [string]$LogRoot
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $ComposeFile) { $ComposeFile = Join-Path $Root 'poc\docker-compose.yml' }
if (-not [IO.Path]::IsPathRooted($ComposeFile)) { $ComposeFile = Join-Path $Root $ComposeFile }
$ComposeFile = [IO.Path]::GetFullPath($ComposeFile)
if (-not $LogRoot) { $LogRoot = Join-Path $Root 'logs' }
if (-not [IO.Path]::IsPathRooted($LogRoot)) { $LogRoot = Join-Path $Root $LogRoot }
$LogRoot = [IO.Path]::GetFullPath($LogRoot)

$Marker = "host_log_test_$([guid]::NewGuid().ToString('N'))"
& docker compose -f $ComposeFile exec -T devcontainer sh -c `
    'printf "%s | HOST_LOG_TEST | %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> /var/log/sandbox/audit.log' `
    sh $Marker
if ($LASTEXITCODE -ne 0) { throw 'Unable to write host-log verification marker in DevContainer.' }

$ClaudeMarker = "claude_hook_test_$([guid]::NewGuid().ToString('N'))"
$SensitiveText = "DO-NOT-LOG-$ClaudeMarker"
$HookJson = @{ session_id=$ClaudeMarker; cwd='/home/vscode/workspace'; hook_event_name='UserPromptSubmit'; prompt=$SensitiveText } | ConvertTo-Json -Compress
$HookJson | & docker compose -f $ComposeFile exec -T devcontainer /usr/local/bin/claude-audit-hook
if ($LASTEXITCODE -ne 0) { throw 'Unable to execute the Claude audit hook.' }

$Applications = @('anthropic','gemini','databricks','tavily','snyk','ado','git','hiddenlayer','mcp')
foreach ($App in $Applications) {
    & docker compose -f $ComposeFile exec -T devcontainer /usr/local/bin/application-audit `
        --app $App --event verification --operation host-export --target test --status success
    if ($LASTEXITCODE -ne 0) { throw "Unable to write $App application audit marker." }
}

Start-Sleep -Seconds 1
$AuditFile = Join-Path $LogRoot 'devcontainer\audit.log'
$ClaudeFile = Join-Path $LogRoot 'devcontainer\claude-events.log'
if (-not (Test-Path $AuditFile)) { throw "Host audit log not found: $AuditFile" }
if (-not (Select-String -LiteralPath $AuditFile -SimpleMatch $Marker -Quiet)) { throw 'Host audit marker not found.' }
if (-not (Test-Path $ClaudeFile)) { throw "Claude event log not found: $ClaudeFile" }
if (-not (Select-String -LiteralPath $ClaudeFile -SimpleMatch $ClaudeMarker -Quiet)) { throw 'Claude audit marker not found.' }
if (Select-String -LiteralPath $ClaudeFile -SimpleMatch $SensitiveText -Quiet) { throw 'Claude audit hook copied prompt content into the host log.' }

foreach ($App in $Applications) {
    $File = Join-Path $LogRoot "devcontainer\$App-events.log"
    if (-not (Test-Path $File)) { throw "Application audit log not found: $File" }
    if (-not (Select-String -LiteralPath $File -SimpleMatch '"event":"verification"' -Quiet)) { throw "Application audit marker not found: $File" }
}

Write-Host "[PASS] Host audit export verified: $AuditFile" -ForegroundColor Green
Write-Host "[PASS] Claude redacted audit export verified: $ClaudeFile" -ForegroundColor Green
Write-Host '[PASS] Application audit export verified for Anthropic, Gemini, Databricks, Tavily, Snyk, ADO, Git, HiddenLayer and MCP.' -ForegroundColor Green
