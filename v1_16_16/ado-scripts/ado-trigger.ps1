#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: PowerShell workflow for triggering approved Azure DevOps pipeline operations.
# Admin maintenance: Update only for ADO API/workflow changes; keep the Bash peer behaviorally equivalent.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/validation.
# Optional Admin guide (SLIM package): docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# ado-trigger.ps1 — Trigger an ADO pipeline via REST API
#
# Can run on the HOST (Windows) or inside the container.
# Uses ADO_PAT from environment or prompts if not set.
#
# Usage:
#   .\ado-trigger.ps1 -PipelineId 42 -Branch main -Wait
#   .\ado-trigger.ps1 -PipelineId 42 -Branch feature/my-branch -Params '{"env":"dev"}' -Wait
# =============================================================================
param(
    [string]$Org        = $env:ADO_ORG,
    [string]$Project    = $env:ADO_PROJECT,
    [int]   $PipelineId,
    [string]$Branch     = "main",
    [string]$Params     = "{}",
    [switch]$Wait,
    [ValidateSet("pat","az")][string]$Auth = (if ($env:ADO_AUTH) { $env:ADO_AUTH } else { "pat" })
)

$ErrorActionPreference = 'Stop'

if (-not $Org)        { $Org = Read-Host "ADO organisation name (or set ADO_ORG)" }
if (-not $Project)    { $Project = Read-Host "ADO project name (or set ADO_PROJECT)" }
if ($PipelineId -eq 0){ $PipelineId = [int](Read-Host "Pipeline ID") }

$BaseUrl = "https://dev.azure.com/$Org/$Project/_apis"
$ApiVer  = "api-version=7.1"

# Build auth header
function Read-SecretText {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-AuthHeader {
    if ($Auth -eq "az") {
        $tok = & az account get-access-token `
            --resource "499b84ac-1321-427f-aa17-267ca6975798" `
            --query accessToken -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tok)) {
            throw 'Azure CLI token acquisition for Azure DevOps failed'
        }
        return @{ Authorization = "Bearer $($tok.Trim())" }
    } else {
        $pat = $env:ADO_PAT
        if (-not $pat) { $pat = Read-SecretText "ADO PAT (or set ADO_PAT)" }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
        return @{ Authorization = "Basic $encoded" }
    }
}

$Headers = Get-AuthHeader

# Trigger pipeline
$Body = @{
    resources           = @{ repositories = @{ self = @{ refName = "refs/heads/$Branch" } } }
    templateParameters  = ($Params | ConvertFrom-Json -AsHashtable)
} | ConvertTo-Json -Depth 5

Write-Host "Triggering pipeline $PipelineId on branch '$Branch'..." -ForegroundColor Cyan

$Response = Invoke-RestMethod `
    -Uri     "$BaseUrl/pipelines/$PipelineId/runs?$ApiVer" `
    -Method  Post `
    -Headers ($Headers + @{ "Content-Type" = "application/json" }) `
    -Body    $Body

$RunId  = $Response.id
$RunUrl = $Response._links.web.href
$State  = $Response.state

Write-Host "  Run ID: $RunId"   -ForegroundColor Green
Write-Host "  State:  $State"
Write-Host "  URL:    $RunUrl"

if (-not $Wait) { exit 0 }

# Poll until complete
Write-Host "`nWaiting for run $RunId to complete..." -ForegroundColor Yellow
$Elapsed = 0; $Timeout = 1800; $Interval = 15

while ($true) {
    Start-Sleep $Interval; $Elapsed += $Interval
    $Headers = Get-AuthHeader
    $Status  = Invoke-RestMethod `
        -Uri     "$BaseUrl/pipelines/$PipelineId/runs/$RunId`?$ApiVer" `
        -Headers $Headers
    $State  = $Status.state
    $Result = if ($Status.result) { $Status.result } else { "unknown" }
    Write-Host "  [$($Elapsed)s] state=$State result=$Result"

    if ($State -eq "completed") {
        Write-Host "`nRun completed: $Result" -ForegroundColor $(if ($Result -eq "succeeded") {"Green"} else {"Red"})
        Write-Host "  URL: $RunUrl"
        if ($Result -eq "succeeded") { exit 0 } else { exit 1 }
    }
    if ($Elapsed -ge $Timeout) {
        throw "Timeout after ${Timeout}s - run still in state: $State"
    }
}
