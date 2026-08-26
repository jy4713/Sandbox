#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Single Windows Admin entry point that selects POC self-hardening or
# Production Ubuntu Pro + USG and then distributes images.
# v1.16.16 adds a POC-only SkipCisAssessment fast-iteration path while preserving hardened-base reuse.
# Admin maintenance: Keep this orchestration thin. New applications should
# normally be wired through the devcontainer Dockerfile and shared validation,
# not hard-coded here.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# =============================================================================
<#
.SYNOPSIS
  Unified Administrator build entry point for the AI Secure Sandbox.

.DESCRIPTION
  Normal mode always resolves external build inputs and rebuilds the hardened
  Ubuntu base before building the DevContainer and Squid images.

  -ReuseHardenedBase enables a faster iterative path. The hardened base is reused
  only when ALL of the following are true:
    - .build.env exists and passes the normal strict build-env validation;
    - BASE_IMAGE and SQUID_BASE_IMAGE are identical digest-pinned references;
    - the exact hardened image reference is available locally or can be pulled;
    - the image carries the expected hardening.method label for SandboxType;
    - the image carries hardening.profile=cis_level1_server.

  If any reuse requirement fails, the script automatically falls back to the
  normal full resolver + hardened-base build path. No manual cleanup is needed.

  A .build.env from the previous package can be copied into this package before
  invoking -ReuseHardenedBase. Alternatively, -BuildEnvSource can copy it for
  you. v1.16.16 updates SANDBOX_VERSION automatically and updates RELEASE_TAG
  when it still equals the previous package version.

.PARAMETER SandboxType
  POC selects self-hardening. Any other value selects Ubuntu Pro + USG.

.PARAMETER UbuntuProToken
  Required only when a non-POC hardened base must actually be rebuilt. A valid
  reused Production hardened base does not require the token again.

.PARAMETER ReuseHardenedBase
  Attempt to reuse the exact hardened BASE_IMAGE/SQUID_BASE_IMAGE already
  recorded in .build.env. Invalid or incomplete state falls back to a rebuild.

.PARAMETER SkipCisAssessment
  POC-only fast-iteration option. Skips the final DevContainer CIS/OpenSCAP
  scanner build and assessment. This option is rejected for Production builds.
  A skipped build is not security-assessed release evidence.

.PARAMETER BuildEnvSource
  Optional path to an existing .build.env from another package directory. The
  file is copied into this package before reuse validation. The source file is
  treated as build configuration, never executed as code.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SandboxType,

    [string]$UbuntuProToken = $env:UBUNTU_PRO_TOKEN,

    [switch]$ReuseHardenedBase,

    [switch]$SkipCisAssessment,

    [string]$BuildEnvSource = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Root
$BuildEnvPath = Join-Path $Root '.build.env'
$PackageVersion = 'v1.16.16'
$ExpectedHardeningMode = if ($SandboxType.ToLowerInvariant() -eq 'poc') { 'poc' } else { 'production' }

if ($SkipCisAssessment -and $ExpectedHardeningMode -ne 'poc') {
    throw '-SkipCisAssessment is permitted only with -SandboxType POC.'
}
if ($SkipCisAssessment) {
    Write-Warning 'SECURITY NOTICE: CIS/OpenSCAP assessment will be skipped. This build is for POC/test use only and must not be promoted as security-assessed release evidence.'
}

function Write-Utf8NoBomLines {
    param([string]$Path, [string[]]$Lines)
    [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

function Set-BuildEnvValue {
    param([string]$Key, [string]$Value)
    $Lines = if (Test-Path $BuildEnvPath) { @(Get-Content $BuildEnvPath -Encoding UTF8) } else { @() }
    $Found = $false
    $Updated = foreach ($Line in $Lines) {
        if ($Line -match "^$([regex]::Escape($Key))=") {
            $Found = $true
            "$Key=$Value"
        }
        else { $Line }
    }
    if (-not $Found) { $Updated += "$Key=$Value" }
    Write-Utf8NoBomLines -Path $BuildEnvPath -Lines $Updated
}

function Get-BuildEnvValue {
    param([string]$Key)
    if (-not (Test-Path $BuildEnvPath)) { return '' }
    foreach ($Line in Get-Content $BuildEnvPath -Encoding UTF8) {
        if ($Line -match "^$([regex]::Escape($Key))=(.*)$") { return $Matches[1] }
    }
    return ''
}

function Update-PackageVersionInBuildEnv {
    if (-not (Test-Path $BuildEnvPath)) { return }
    $OldVersion = Get-BuildEnvValue -Key 'SANDBOX_VERSION'
    $OldRelease = Get-BuildEnvValue -Key 'RELEASE_TAG'
    Set-BuildEnvValue -Key 'SANDBOX_VERSION' -Value $PackageVersion
    if ([string]::IsNullOrWhiteSpace($OldRelease) -or $OldRelease -eq $OldVersion -or $OldRelease -eq 'v1.16.4') {
        Set-BuildEnvValue -Key 'RELEASE_TAG' -Value $PackageVersion
    }
}

function Apply-HardenedBaseEnvironment {
    $HardenedEnv = Join-Path $Root 'hardened-base-build\hardened-base.env'
    if (-not (Test-Path $HardenedEnv)) {
        throw "Hardened base environment file not found: $HardenedEnv"
    }

    $Values = @{}
    foreach ($Line in Get-Content $HardenedEnv -Encoding UTF8) {
        if ($Line -match '^(BASE_IMAGE|SQUID_BASE_IMAGE)=(.+)$') {
            $Values[$Matches[1]] = $Matches[2]
        }
    }

    foreach ($RequiredKey in @('BASE_IMAGE', 'SQUID_BASE_IMAGE')) {
        if (-not $Values.ContainsKey($RequiredKey)) {
            throw "$RequiredKey was not produced by the hardened-base builder."
        }
        Set-BuildEnvValue -Key $RequiredKey -Value $Values[$RequiredKey]
    }
}

function Test-ReusableHardenedBase {
    Write-Host '[reuse] Checking whether the existing hardened base can be reused...' -ForegroundColor Cyan

    try {
        $Build = & (Join-Path $Root 'scripts\common\Load-BuildEnv.ps1') -EnvFile $BuildEnvPath
    }
    catch {
        Write-Warning "[reuse] .build.env is incomplete or invalid: $($_.Exception.Message)"
        return $false
    }

    if ($Build['BASE_IMAGE'] -ne $Build['SQUID_BASE_IMAGE']) {
        Write-Warning '[reuse] BASE_IMAGE and SQUID_BASE_IMAGE are not the same digest.'
        return $false
    }

    $Ref = $Build['BASE_IMAGE']
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warning '[reuse] docker is unavailable; hardened-base reuse cannot be verified.'
        return $false
    }

    & docker image inspect $Ref *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[reuse] Exact digest is not materialized locally; attempting docker pull: $Ref" -ForegroundColor DarkGray
        & docker pull $Ref *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[reuse] Hardened base digest is not available locally and cannot be pulled: $Ref"
            return $false
        }
    }

    $Method = (& docker image inspect $Ref --format '{{ index .Config.Labels "hardening.method" }}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Warning '[reuse] Unable to read hardening.method label from the candidate base image.'
        return $false
    }
    $Profile = (& docker image inspect $Ref --format '{{ index .Config.Labels "hardening.profile" }}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Write-Warning '[reuse] Unable to read hardening.profile label from the candidate base image.'
        return $false
    }

    if ($Method -ne $ExpectedHardeningMode) {
        Write-Warning "[reuse] Hardened base mode mismatch. Expected '$ExpectedHardeningMode', found '$Method'."
        return $false
    }
    if ($Profile -ne 'cis_level1_server') {
        Write-Warning "[reuse] Hardened base profile mismatch. Expected 'cis_level1_server', found '$Profile'."
        return $false
    }

    Write-Host '[reuse] Existing hardened base passed validation.' -ForegroundColor Green
    Write-Host "[reuse] BASE_IMAGE = $Ref" -ForegroundColor Green
    return $true
}

function Invoke-FullInputResolutionAndHardening {
    Write-Host '[build] Running full resolver + hardened-base build path.' -ForegroundColor Cyan

    & scripts\supply-chain\resolve-base-digests.ps1 -Write
    if ($LASTEXITCODE -ne 0) { throw 'Base digest resolver failed.' }
    & scripts\supply-chain\resolve-tool-artifacts.ps1 -Write
    if ($LASTEXITCODE -ne 0) { throw 'Tool artifact resolver failed.' }

    # Capture the resolver-produced immutable upstream Ubuntu digest before the
    # hardened-base builder replaces BASE_IMAGE/SQUID_BASE_IMAGE with its own
    # hardened digest. This keeps full fallback builds reproducible.
    $ResolvedInputs = & (Join-Path $Root 'scripts\common\Load-BuildEnv.ps1') -EnvFile $BuildEnvPath
    $SourceImage = $ResolvedInputs['BASE_IMAGE']

    if ($ExpectedHardeningMode -eq 'poc') {
        & scripts\hardening\build-hardened-base.ps1 -SandboxType 'POC' -SourceImage $SourceImage
        if ($LASTEXITCODE -ne 0) { throw 'POC hardened-base build failed.' }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($UbuntuProToken)) {
            throw 'Ubuntu Pro token is required because the Production hardened base must be rebuilt.'
        }
        & scripts\hardening\build-hardened-base.ps1 `
            -SandboxType $SandboxType `
            -UbuntuProToken $UbuntuProToken `
            -SourceImage $SourceImage
        if ($LASTEXITCODE -ne 0) { throw 'Production hardened-base build failed.' }
    }

    Apply-HardenedBaseEnvironment
    Update-PackageVersionInBuildEnv
}

# -----------------------------------------------------------------------------
# [0] Optional migration of a previously resolved .build.env.
# -----------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($BuildEnvSource)) {
    $ResolvedSource = (Resolve-Path $BuildEnvSource).Path
    $ResolvedTarget = [IO.Path]::GetFullPath($BuildEnvPath)
    if ($ResolvedSource -ne $ResolvedTarget) {
        Copy-Item -LiteralPath $ResolvedSource -Destination $BuildEnvPath -Force
        Write-Host "[INFO] Copied existing build configuration: $ResolvedSource -> $BuildEnvPath" -ForegroundColor Yellow
    }
}

if (-not (Test-Path $BuildEnvPath)) {
    Copy-Item '.build.env.example' $BuildEnvPath
    Write-Host '[INFO] Created .build.env from .build.env.example.' -ForegroundColor Yellow
}
Update-PackageVersionInBuildEnv

# -----------------------------------------------------------------------------
# [1] Attempt reuse only when explicitly requested.
# -----------------------------------------------------------------------------
$UsingReusedHardenedBase = $false
if ($ReuseHardenedBase) {
    $UsingReusedHardenedBase = Test-ReusableHardenedBase
    if (-not $UsingReusedHardenedBase) {
        Write-Warning '[reuse] Reuse requirements were not met. Falling back automatically to a new hardened-base build.'
    }
}

# -----------------------------------------------------------------------------
# [2] Normal path or automatic fallback.
# -----------------------------------------------------------------------------
if (-not $UsingReusedHardenedBase) {
    Invoke-FullInputResolutionAndHardening
}
else {
    Write-Host '[reuse] Skipping upstream base-image resolution and hardened-base generation for this iterative build.' -ForegroundColor Green
    Write-Host '[reuse] Refreshing and pinning the current ucode main commit required for headless PAT support...' -ForegroundColor Cyan
    & scripts\supply-chain\resolve-tool-artifacts.ps1 -Write -UcodeOnly
    if ($LASTEXITCODE -ne 0) { throw 'ucode immutable-ref refresh failed.' }
}

# Final strict validation before building runtime images, regardless of path.
$null = & (Join-Path $Root 'scripts\common\Load-BuildEnv.ps1') -EnvFile $BuildEnvPath

# -----------------------------------------------------------------------------
# [3] Build/distribute final images.
# -----------------------------------------------------------------------------
if ($ExpectedHardeningMode -eq 'poc') {
    Write-Host '=== Admin build: POC / self-hardened Ubuntu 24.04 ===' -ForegroundColor Cyan
    if ($UsingReusedHardenedBase) { Write-Host '[reuse] POC hardened base reused.' -ForegroundColor Green }

    & scripts\poc\build-and-export.ps1 -SkipCisAssessment:$SkipCisAssessment
    if ($LASTEXITCODE -ne 0) { throw 'POC build/export failed.' }

    Write-Host '[OK] POC TAR bundle ready under poc\images.' -ForegroundColor Green
    Write-Host 'Developer action: run scripts\poc\load-and-start.ps1.' -ForegroundColor Green
    exit 0
}

Write-Host "=== Admin build: $SandboxType / Ubuntu Pro + USG ===" -ForegroundColor Cyan
if ($UsingReusedHardenedBase) { Write-Host '[reuse] Production hardened base reused; Ubuntu Pro hardening was not rerun.' -ForegroundColor Green }

$env:REQUIRE_CIS_PASS = 'true'
& scripts\platform\02-setup-ecr.ps1
if ($LASTEXITCODE -ne 0) { throw 'Production ECR build/push failed.' }

Write-Host '[OK] Production images pushed to ECR with approved digests.' -ForegroundColor Green
Write-Host '[OK] Central approved-image manifest published to SSM. Existing Developer packages will pick up the release on the next pull-and-start.' -ForegroundColor Green
