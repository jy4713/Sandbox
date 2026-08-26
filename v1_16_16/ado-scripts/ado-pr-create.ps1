#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: PowerShell workflow for creating Azure DevOps pull requests using approved authentication.
# Admin maintenance: Update only for ADO API/workflow changes; keep the Bash peer behaviorally equivalent.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/validation.
# Optional Admin guide (SLIM package): docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# ado-pr-create.ps1 — Create a Pull Request in Azure DevOps
#
# Enforces sandbox policy: AI agent changes must go via PR, never direct push.
#
# Usage:
#   .\ado-pr-create.ps1 -Title "feat: add X" -Source feature/my-branch
#   .\ado-pr-create.ps1 -Title "feat: add X" -Source feature/my-branch -Reviewers "user@org.com" -Draft
# =============================================================================
param(
    [string]$Org         = $env:ADO_ORG,
    [string]$Project     = $env:ADO_PROJECT,
    [string]$Repo        = $env:ADO_REPO,
    [string]$Title,
    [string]$Source,
    [string]$Target      = "main",
    [string]$Description = "",
    [string]$Reviewers   = "",
    [switch]$Draft,
    [switch]$AutoComplete,
    [ValidateSet("pat","az")][string]$Auth = (if ($env:ADO_AUTH) { $env:ADO_AUTH } else { "pat" })
)

$ErrorActionPreference = 'Stop'

if (-not $Org)     { $Org = Read-Host "ADO organisation (or set ADO_ORG)" }
if (-not $Project) { $Project = Read-Host "ADO project (or set ADO_PROJECT)" }
if (-not $Repo)    { $Repo = Read-Host "Repository name (or set ADO_REPO)" }
if (-not $Title)   { $Title = Read-Host "PR title" }
if (-not $Source)  { $Source = Read-Host "Source branch (e.g. feature/my-change)" }

# Guard: prevent PR from main as source
if ($Source -in @("main","master")) {
    throw "Cannot create PR from main/master as source. Create a feature branch first."
}

$BaseUrl = "https://dev.azure.com/$Org/$Project/_apis"
$ApiVer  = "api-version=7.1"

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
        if (-not $pat) { $pat = Read-SecretText "ADO PAT" }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
        return @{ Authorization = "Basic $encoded" }
    }
}

$Headers = Get-AuthHeader

# Resolve reviewer IDs
$ReviewerObjs = @()
if ($Reviewers) {
    foreach ($upn in ($Reviewers -split ",")) {
        $upn = $upn.Trim()
        $idResult = Invoke-RestMethod `
            -Uri     "https://vssps.dev.azure.com/$Org/_apis/identities?searchFilter=MailAddress&filterValue=$upn&api-version=7.1" `
            -Headers $Headers
        $id = $idResult.value[0].id
        if ($id) { $ReviewerObjs += @{ id = $id } }
        else      { Write-Warning "Could not resolve reviewer: $upn" }
    }
}

# Create PR
$Body = @{
    title           = $Title
    description     = $Description
    sourceRefName   = "refs/heads/$Source"
    targetRefName   = "refs/heads/$Target"
    isDraft         = $Draft.IsPresent
    reviewers       = $ReviewerObjs
} | ConvertTo-Json -Depth 5

Write-Host "Creating PR: '$Title'" -ForegroundColor Cyan
Write-Host "  $Source -> $Target  (draft: $($Draft.IsPresent))"

$Response = Invoke-RestMethod `
    -Uri     "$BaseUrl/git/repositories/$Repo/pullrequests?$ApiVer" `
    -Method  Post `
    -Headers ($Headers + @{ "Content-Type" = "application/json" }) `
    -Body    $Body

$PrId  = $Response.pullRequestId
$PrUrl = $Response._links.web.href

Write-Host "`n  [OK] PR #$PrId created" -ForegroundColor Green
Write-Host "  URL: $PrUrl"

# Auto-complete
if ($AutoComplete) {
    $SelfId = (Invoke-RestMethod `
        -Uri     "https://vssps.dev.azure.com/$Org/_apis/profile/profiles/me?api-version=7.1" `
        -Headers (Get-AuthHeader)).id
    Invoke-RestMethod `
        -Uri     "$BaseUrl/git/repositories/$Repo/pullrequests/$PrId`?$ApiVer" `
        -Method  Patch `
        -Headers ((Get-AuthHeader) + @{ "Content-Type" = "application/json" }) `
        -Body    (@{ autoCompleteSetBy = @{ id = $SelfId }; completionOptions = @{ deleteSourceBranch = $true; mergeStrategy = "squash" } } | ConvertTo-Json -Depth 5) | Out-Null
    Write-Host "  Auto-complete: enabled"
}
