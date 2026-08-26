#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Safely parses and validates .build.env for Windows Admin workflows without executing it as code.
# Admin maintenance: When a new build-time application requires a version/hash variable, add it to validation/default handling here and in load-build-env.sh.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
<#
.SYNOPSIS
  Shared .build.env loader for admin scripts. Windows equivalent of
  load-build-env.sh.

.DESCRIPTION
  Safely loads KEY=VALUE build parameters from .build.env (or -EnvFile /
  $env:BUILD_ENV_FILE) and returns them as a hashtable. The file is parsed
  as literal text line-by-line — never invoked as code — so a tampered
  .build.env cannot become arbitrary code execution in an admin build
  context.

  Validation performed (fail-closed, throws on any violation):
    - All required keys present and not left as REPLACE_* placeholders
      (BASE_IMAGE, NODE_IMAGE, SQUID_BASE_IMAGE,
      CLAUDE_CODE_VERSION, GEMINI_CLI_VERSION, AWSCLI_URL/SHA256,
      DATABRICKS_CLI_VERSION/URL/SHA256, UCODE_GIT_REF, SSG_VERSION/URL/
      SHA256, CIS_PROFILE_ID)
    - *_SHA256 values are exactly 64 hex chars; UCODE_GIT_REF is 40 hex
    - All three image references are digest-pinned (repo@sha256:...)
  Also supplies defaults: DEVCONTAINER_TARGET=baseline,
  SANDBOX_VERSION=v1.16.16, NPM_REGISTRY, GCM_VERSION, REQUIRE_CIS_PASS.

.PARAMETER EnvFile
  Optional path to the env file. Default: .build.env at the package root
  (or $env:BUILD_ENV_FILE when set).

.EXAMPLE
  $B = & scripts\common\Load-BuildEnv.ps1
  $B['BASE_IMAGE']
  # When it reports missing values:
  #   cp .build.env.example .build.env
  #   scripts\supply-chain\resolve-base-digests.ps1 -Write
  #   scripts\supply-chain\resolve-tool-artifacts.ps1 -Write
#>
[CmdletBinding()]
param([string]$EnvFile)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $EnvFile) { $EnvFile = if ($env:BUILD_ENV_FILE) { $env:BUILD_ENV_FILE } else { Join-Path $Root '.build.env' } }
if (-not (Test-Path $EnvFile)) { throw ".build.env not found at $EnvFile`nCopy .build.env.example, then run both supply-chain resolver scripts." }

$BuildEnv=@{}
Get-Content $EnvFile -Encoding UTF8 | ForEach-Object {
    $line=$_.TrimEnd("`r","`n")
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { return }
    $idx=$line.IndexOf('='); if ($idx -lt 1) { throw "Invalid line in .build.env: $line" }
    $key=$line.Substring(0,$idx).Trim(); $val=$line.Substring($idx+1)
    if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid key in .build.env: $key" }
    $BuildEnv[$key]=$val
}

$Required=@(
 'BASE_IMAGE','NODE_IMAGE','SQUID_BASE_IMAGE',
 'CLAUDE_CODE_VERSION','GEMINI_CLI_VERSION','TAVILY_CLI_VERSION','TAVILY_MCP_VERSION','MCP_REMOTE_VERSION','SNYK_CLI_VERSION','AWSCLI_URL','AWSCLI_SHA256',
 'DATABRICKS_CLI_VERSION','DATABRICKS_CLI_URL','DATABRICKS_CLI_SHA256','UCODE_GIT_REF',
 'SSG_VERSION','SSG_URL','SSG_SHA256','CIS_PROFILE_ID'
)
$Missing=@($Required | Where-Object { [string]::IsNullOrWhiteSpace($BuildEnv[$_]) -or $BuildEnv[$_] -like '*REPLACE_*' })
if ($Missing.Count) { throw "Missing/unresolved .build.env values:`n  - $($Missing -join "`n  - ")`nRun both supply-chain resolver scripts with -Write." }
foreach($k in @('AWSCLI_SHA256','DATABRICKS_CLI_SHA256','SSG_SHA256')) { if ($BuildEnv[$k] -notmatch '^[0-9a-fA-F]{64}$') { throw "$k must be 64 hex characters" } }
if ($BuildEnv['UCODE_GIT_REF'] -notmatch '^[0-9a-fA-F]{40}$') { throw 'UCODE_GIT_REF must be a 40-hex commit' }
foreach($k in @('BASE_IMAGE','NODE_IMAGE','SQUID_BASE_IMAGE')) { if ($BuildEnv[$k] -notlike '*@sha256:*') { throw "$k must be digest-pinned: $($BuildEnv[$k])" } }

if (-not $BuildEnv['DEVCONTAINER_TARGET']) { $BuildEnv['DEVCONTAINER_TARGET']='baseline' }
if (-not $BuildEnv['SANDBOX_VERSION']) { $BuildEnv['SANDBOX_VERSION']='v1.16.16' }
if (-not $BuildEnv['RELEASE_TAG']) { $BuildEnv['RELEASE_TAG']=$BuildEnv['SANDBOX_VERSION'] }
if (-not $BuildEnv['NPM_REGISTRY']) { $BuildEnv['NPM_REGISTRY']='https://registry.npmjs.org' }
if (-not $BuildEnv['GCM_VERSION']) { $BuildEnv['GCM_VERSION']='2.5.0' }
if ($null -eq $BuildEnv['GCM_SHA256']) { $BuildEnv['GCM_SHA256']='' }
if (-not $BuildEnv['REQUIRE_CIS_PASS']) { $BuildEnv['REQUIRE_CIS_PASS']='false' }

Write-Host "[build-env] Loaded: $EnvFile" -ForegroundColor DarkGray
Write-Host "[build-env]   BASE_IMAGE = $($BuildEnv['BASE_IMAGE'])" -ForegroundColor DarkGray
Write-Host "[build-env]   NODE_IMAGE = $($BuildEnv['NODE_IMAGE'])" -ForegroundColor DarkGray
Write-Host "[build-env]   TARGET     = $($BuildEnv['DEVCONTAINER_TARGET'])" -ForegroundColor DarkGray
Write-Host "[build-env]   RELEASE    = $($BuildEnv['RELEASE_TAG'])" -ForegroundColor DarkGray
return $BuildEnv
