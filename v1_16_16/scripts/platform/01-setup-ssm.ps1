#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Admin bootstrap for AWS SSM Parameter Store names used by Sandbox
# applications. Host-side Sentinel forwarding credentials/configuration are not
# provisioned by this application bootstrap.
# Admin maintenance: Add/remove parameter names here whenever an application
# gains or loses runtime secrets. Never embed real secret values in the script
# or repository.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
<#
.SYNOPSIS
  Populate runtime credentials and non-secret identifiers in AWS SSM Parameter
  Store. Administrator use only.

.DESCRIPTION
  This script prompts interactively for the sandbox credentials required by the
  approved applications. Secret values are written as SecureString parameters;
  non-secret identifiers are written as String parameters.

  The runtime devcontainer does not automatically export these values. Instead,
  .devcontainer/scripts/run-with-ssm-secrets.sh retrieves the minimum values for
  one child process at a time.

  Environment overrides:
    SSM_PREFIX       Default: /sandbox
    AWS_REGION       Default: eu-west-2
    SSM_KMS_KEY_ID   Default: alias/aws/ssm

  APPLICATION MAINTENANCE RULE:
  When adding a new secret-backed application, update BOTH this PowerShell file
  and 01-setup-ssm.sh, then add the corresponding runtime profile to
  run-with-ssm-secrets.sh. Document parameter names in .env.example.
#>

$ErrorActionPreference = 'Stop'

$Prefix = if ($env:SSM_PREFIX) { $env:SSM_PREFIX.TrimEnd('/') } else { '/sandbox' }
$Region = if ($env:AWS_REGION) { $env:AWS_REGION } else { 'eu-west-2' }
$KmsKey = if ($env:SSM_KMS_KEY_ID) { $env:SSM_KMS_KEY_ID } else { 'alias/aws/ssm' }

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureValue)

    $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
    }
}

function Set-SsmSecret {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $Version = & aws ssm put-parameter `
        --name "$Prefix/$Name" `
        --description $Description `
        --value $Value `
        --type SecureString `
        --key-id $KmsKey `
        --overwrite `
        --region $Region `
        --query Version `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "SSM PutParameter failed: $Name"
    }

    Write-Host "  [OK] $Name (v$Version)" -ForegroundColor Green
}

function Set-SsmString {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $Version = & aws ssm put-parameter `
        --name "$Prefix/$Name" `
        --description $Description `
        --value $Value `
        --type String `
        --overwrite `
        --region $Region `
        --query Version `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "SSM PutParameter failed: $Name"
    }

    Write-Host "  [OK] $Name (v$Version)" -ForegroundColor Green
}

Write-Host "=== SSM Parameter Setup === prefix=$Prefix region=$Region" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# [1] Databricks
# -----------------------------------------------------------------------------
Write-Host "`n--- Direct AI provider credentials ---"
$SecretValue = ConvertTo-PlainText (Read-Host '  Anthropic Claude API key' -AsSecureString)
Set-SsmSecret -Name 'claude-api-key' -Description 'Anthropic Claude API key for direct Claude Code access' -Value $SecretValue
$SecretValue = $null

$SecretValue = ConvertTo-PlainText (Read-Host '  Google Gemini API key' -AsSecureString)
Set-SsmSecret -Name 'gemini-api-key' -Description 'Google Gemini API key for direct Gemini CLI access' -Value $SecretValue
$SecretValue = $null

Write-Host "`n--- Databricks (used by ucode and Databricks CLI) ---"
$SecretValue = ConvertTo-PlainText (Read-Host '  Databricks PAT' -AsSecureString)
Set-SsmSecret -Name 'databricks-token' -Description 'Databricks Personal Access Token' -Value $SecretValue
$SecretValue = $null

Write-Host "`n--- Databricks SQL MCP (separate SSM path; same PAT value is acceptable for POC) ---"
$SecretValue = ConvertTo-PlainText (Read-Host '  Databricks SQL MCP PAT' -AsSecureString)
Set-SsmSecret -Name 'databricks-sql-mcp-token' -Description 'Databricks PAT dedicated to managed SQL MCP' -Value $SecretValue
$SecretValue = $null

# -----------------------------------------------------------------------------
# [2] Azure DevOps (approved SSM-backed mode: PAT)
# -----------------------------------------------------------------------------
Write-Host "`n--- Azure DevOps (approved SSM-backed mode: PAT) ---"
$AdoOrg = Read-Host '  ADO organisation name'
$AdoProject = Read-Host '  ADO project name'
$AdoRepo = Read-Host '  ADO repository name'

Set-SsmString -Name 'ado-org' -Description 'ADO organisation' -Value $AdoOrg
Set-SsmString -Name 'ado-project' -Description 'ADO project' -Value $AdoProject
Set-SsmString -Name 'ado-repo' -Description 'ADO default repository' -Value $AdoRepo

$SecretValue = ConvertTo-PlainText (Read-Host '  ADO PAT' -AsSecureString)
Set-SsmSecret -Name 'ado-pat' -Description 'ADO Personal Access Token' -Value $SecretValue
$SecretValue = $null

# -----------------------------------------------------------------------------
# [3] APPLICATION MAINTENANCE ZONE - APPLICATION SECRETS
# Add/remove application-specific SSM parameters in this section. Use
# SecureString for credentials and keep names synchronized with
# run-with-ssm-secrets.sh. Mirror every change in 01-setup-ssm.sh.
# -----------------------------------------------------------------------------
Write-Host "`n--- Tavily ---"
$SecretValue = ConvertTo-PlainText (Read-Host '  Tavily API key' -AsSecureString)
Set-SsmSecret -Name 'tavily-api-key' -Description 'Tavily API key' -Value $SecretValue
$SecretValue = $null

Write-Host "`n--- Snyk ---"
$SecretValue = ConvertTo-PlainText (Read-Host '  Snyk token' -AsSecureString)
Set-SsmSecret -Name 'snyk-token' -Description 'Snyk API token' -Value $SecretValue
$SecretValue = $null

Write-Host "`n--- HiddenLayer ---"
$HiddenLayerClientId = ConvertTo-PlainText (Read-Host '  HiddenLayer client ID' -AsSecureString)
$HiddenLayerClientSecret = ConvertTo-PlainText (Read-Host '  HiddenLayer client secret' -AsSecureString)
Set-SsmSecret -Name 'hiddenlayer-client-id' -Description 'HiddenLayer client ID' -Value $HiddenLayerClientId
Set-SsmSecret -Name 'hiddenlayer-client-secret' -Description 'HiddenLayer client secret' -Value $HiddenLayerClientSecret
$HiddenLayerClientId = $null
$HiddenLayerClientSecret = $null

# -----------------------------------------------------------------------------

# [4] Verify only parameter names/types. Values are never printed.
# -----------------------------------------------------------------------------
Write-Host "`n--- Registered parameters ---"
& aws ssm get-parameters-by-path `
    --path $Prefix `
    --region $Region `
    --query 'Parameters[*].{Name:Name,Type:Type}' `
    --output table

if ($LASTEXITCODE -ne 0) {
    throw 'SSM verification failed.'
}

Write-Host '[OK] SSM setup complete.' -ForegroundColor Green
