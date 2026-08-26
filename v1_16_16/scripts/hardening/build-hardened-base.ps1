#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Builds the selected hardened Ubuntu 24.04 base: POC self-hardening or non-POC Ubuntu Pro + USG.
# Admin maintenance: Application package changes do not belong here. Modify only hardening inputs, profiles, evidence generation, or base-image security controls.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
<#
.SYNOPSIS
  Builds ONE hardened Ubuntu 24.04 base image, selected by -SandboxType.

.DESCRIPTION
  -SandboxType Poc        -> self-hardened image (OpenSCAP auto-remediation
                              against the cis_level1_server profile). No
                              Ubuntu Pro subscription required. Matches the
                              "OpenSCAP hardened" branch validated in
                              Images_Compare_Script_test/Run-ImageTest.ps1.

  Any non-POC SandboxType -> Ubuntu Pro + USG (Ubuntu Security Guide)
                              hardened image. Requires a valid Ubuntu Pro
                              token. Matches the "USG hardened" branch
                              validated in the same reference script.

  The resulting image is intentionally generic (OS-level hardening only, no
  Node/Python/AI CLI/Squid packages). It is meant to be pushed to a registry
  and then referenced as BOTH:
    BASE_IMAGE=<pushed-ref>@sha256:<digest>         (.devcontainer/Dockerfile)
    SQUID_BASE_IMAGE=<pushed-ref>@sha256:<digest>   (squid/Dockerfile)
  in .build.env, so the devcontainer and the Squid egress proxy inherit the
  EXACT SAME hardened OS layer.

  This script only produces the hardened base layer. It does not modify or
  replace .devcontainer/Dockerfile, .devcontainer/cis-level1-harden.sh, or
  squid/Dockerfile.

  Functionally identical to build-hardened-base.sh (Bash). All comments and
  output are in English by design.

.EXAMPLE
  # POC self-hardening (OpenSCAP), digest resolved via the local scratch registry
  .\build-hardened-base.ps1 -SandboxType Poc

.EXAMPLE
  # Production hardening (Ubuntu Pro + USG) — still no -Registry needed;
  # the FINAL images (not this base) go to ECR later via deploy-ecr.ps1
  .\build-hardened-base.ps1 -SandboxType Production `
      -UbuntuProToken "C-xxxxxxxxxxxxxxxxxxxxxxxx"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SandboxType,

    [string]$UbuntuProToken = $env:UBUNTU_PRO_TOKEN,

    # Starting OS image. Pass a digest-pinned reference from
    # resolve-base-digests.sh for a fully reproducible build, e.g.
    # ubuntu:24.04@sha256:....
    [string]$SourceImage = "ubuntu:24.04",

    # Optional. Push the hardened BASE image to a shared registry instead of
    # the disposable local one — only useful if you reuse this base image
    # across multiple admin build hosts. NOT required for either Poc or
    # Production: it exists only so this script can obtain a real registry
    # digest to satisfy .build.env's existing "BASE_IMAGE must be
    # repo@sha256:..." validation (a plain `docker commit` result has no
    # digest until it is pushed somewhere). If omitted, an ephemeral,
    # admin-host-only "digest resolution scratch registry" is started
    # instead. Developers never see or use this scratch registry, and it has
    # nothing to do with how the FINAL devcontainer/squid images
    # reach developers — that is still tar export for POC / ECR push for
    # Production via the existing scripts/poc/build-and-export.ps1 and
    # scripts/ecr/deploy-ecr.ps1, unchanged.
    [string]$Registry = "",

    [string]$ImageRepoName = "ai-sandbox-hardened-base",
    [string]$Tag = "",

    [string]$SsgUrl = "",
    [string]$SsgSha256 = "",
    [string]$ComplianceDataStreamPath = "",
    [string]$BuildEnvFile = "",

    [string]$WorkDir = (Join-Path (Get-Location) "hardened-base-build"),

    # Build and commit locally only. The resulting image will NOT be
    # digest-pinned and CANNOT be used directly as BASE_IMAGE /
    # SQUID_BASE_IMAGE (those require an "@sha256:" registry digest).
    [switch]$SkipPush,

    [int]$LocalRegistryPort = 5000,
    [switch]$KeepContainers,

    # Downloads the LATEST ComplianceAsCode release from GitHub instead of
    # requiring a pinned SSG_URL/SSG_SHA256. Breaks supply-chain pinning;
    # use only for one-off local experimentation.
    [switch]$RefreshComplianceContent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RequestedSandboxType = $SandboxType.ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($RequestedSandboxType)) { throw "-SandboxType is required" }
$SandboxTypeLower = if ($RequestedSandboxType -eq "poc") { "poc" } else { "production" }
Write-Host "[policy] requested SandboxType='$RequestedSandboxType' -> hardening='$SandboxTypeLower'" -ForegroundColor DarkCyan

if ([string]::IsNullOrWhiteSpace($Tag)) {
    $Tag = "$SandboxTypeLower-24.04-$([DateTime]::UtcNow.ToString('yyyyMMdd'))"
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Best-effort: repo root is two levels above scripts/hardening/.
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
if ([string]::IsNullOrWhiteSpace($BuildEnvFile)) {
    $BuildEnvFile = Join-Path $RepoRoot ".build.env"
}

# Admin-host-only scratch registry used purely to obtain a real digest for
# the hardened base image. Never used for developer distribution.
$LocalRegistryName = "ai-sandbox-hardened-base-digest-scratch-registry"
$CommonImage = "ai-sandbox-hardening-common:build"
$RawImage    = "ai-sandbox-hardening-raw:$SandboxTypeLower"
$BuildContainer = "ai-sandbox-hardening-builder"

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 82) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 82) -ForegroundColor DarkCyan
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $Content = $Content.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Docker {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$IgnoreExitCode)
    & docker @Arguments
    $rc = $LASTEXITCODE
    if (($rc -ne 0) -and (-not $IgnoreExitCode)) {
        throw "docker $($Arguments -join ' ') failed with exit code $rc"
    }
    return $rc
}

function Get-DockerText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $out = & docker @Arguments 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        throw "docker $($Arguments -join ' ') failed with exit code $rc`n$($out | Out-String)"
    }
    return ($out | Out-String).Trim()
}

function Convert-SecureStringToPlain {
    param([Security.SecureString]$SecureString)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-EnvValue {
    # Reads KEY=VALUE from a simple .build.env-style file without executing it.
    param([string]$File, [string]$Key)
    if (-not (Test-Path $File)) { return "" }
    $line = Get-Content $File | Where-Object { $_ -match "^\s*$Key=" } | Select-Object -Last 1
    if (-not $line) { return "" }
    return ($line -replace "^\s*$Key=", "").Trim()
}

Write-Step "AI Sandbox - Hardened Base Image Builder"
Write-Host "  sandbox type   : $SandboxTypeLower"
Write-Host "  source image   : $SourceImage"
Write-Host "  work dir       : $WorkDir"
Write-Host "  image name:tag : ${ImageRepoName}:${Tag}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found. Install/start Docker Desktop."
}

$osType = Get-DockerText -Arguments @("info", "--format", "{{.OSType}}")
if ($osType -ne "linux") {
    throw "Docker Desktop must be in Linux container mode. Current OSType: $osType"
}

if ($SandboxTypeLower -eq "production" -and -not $UbuntuProToken) {
    Write-Host ""
    Write-Host "Ubuntu Pro token is required for any non-POC -SandboxType." -ForegroundColor Yellow
    $secure = Read-Host "Enter Ubuntu Pro token (hidden)" -AsSecureString
    $UbuntuProToken = Convert-SecureStringToPlain $secure
    if (-not $UbuntuProToken) { throw "Ubuntu Pro token not supplied." }
}

New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir "context") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir "results") | Out-Null
$Ctx = Join-Path $WorkDir "context"

# ---------------------------------------------------------------------------
# Resolve pinned ComplianceAsCode (SSG) content
# ---------------------------------------------------------------------------
if (-not $SsgUrl)    { $SsgUrl    = Read-EnvValue -File $BuildEnvFile -Key "SSG_URL" }
if (-not $SsgSha256) { $SsgSha256 = Read-EnvValue -File $BuildEnvFile -Key "SSG_SHA256" }

$ScapXml = Join-Path $Ctx "ssg-ubuntu2404-ds.xml"

if ($ComplianceDataStreamPath) {
    Write-Step "Using local compliance data stream: $ComplianceDataStreamPath"
    if (-not (Test-Path $ComplianceDataStreamPath)) {
        throw "File not found: $ComplianceDataStreamPath"
    }
    Copy-Item -Force $ComplianceDataStreamPath $ScapXml
}
elseif ($SsgUrl -and $SsgSha256) {
    Write-Step "Downloading pinned SSG content: $SsgUrl"
    $downloadDir = Join-Path $Ctx "_ssg-download"
    $extractDir = Join-Path $downloadDir "extract"
    Remove-Item -Recurse -Force $downloadDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    $archive = Join-Path $downloadDir "ssg.zip"
    Invoke-WebRequest -Uri $SsgUrl -OutFile $archive

    $actualHash = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $SsgSha256.ToLowerInvariant()) {
        throw "SSG bundle SHA-256 mismatch. expected=$SsgSha256 actual=$actualHash"
    }

    Expand-Archive -Path $archive -DestinationPath $extractDir -Force
    $found = Get-ChildItem -Path $extractDir -Recurse -File -Filter "ssg-ubuntu2404-ds.xml" |
        Select-Object -First 1
    if (-not $found) { throw "ssg-ubuntu2404-ds.xml not found inside SSG bundle." }
    Copy-Item -Force $found.FullName $ScapXml
}
elseif ($RefreshComplianceContent) {
    Write-Warning "-RefreshComplianceContent breaks supply-chain pinning. Downloading LATEST release..."
    $headers = @{ "User-Agent" = "ai-sandbox-hardened-base"; "Accept" = "application/vnd.github+json" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ComplianceAsCode/content/releases/latest" -Headers $headers
    $asset = $release.assets |
        Where-Object { $_.name -match '^scap-security-guide-.*\.zip$' -and $_.name -notmatch '\.sha512$' } |
        Select-Object -First 1
    if (-not $asset) { throw "No pre-built scap-security-guide zip found in the latest release." }

    $downloadDir = Join-Path $Ctx "_ssg-download"
    $extractDir = Join-Path $downloadDir "extract"
    Remove-Item -Recurse -Force $downloadDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    $archive = Join-Path $downloadDir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -Headers $headers
    Expand-Archive -Path $archive -DestinationPath $extractDir -Force

    $found = Get-ChildItem -Path $extractDir -Recurse -File -Filter "ssg-ubuntu2404-ds.xml" |
        Select-Object -First 1
    if (-not $found) { throw "ssg-ubuntu2404-ds.xml not found after extracting latest release." }
    Copy-Item -Force $found.FullName $ScapXml
}
else {
    throw @"
No pinned ComplianceAsCode content available.
Provide one of:
  -ComplianceDataStreamPath <path-to-ssg-ubuntu2404-ds.xml>
  -SsgUrl <url> -SsgSha256 <hex64>
  (or make sure SSG_URL / SSG_SHA256 already exist in .build.env)
  -RefreshComplianceContent   (breaks pinning; local experimentation only)
"@
}

Write-Host "  [OK] SSG content ready: $ScapXml" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Write build context (Dockerfiles + scripts)
# ---------------------------------------------------------------------------
$installCommon = @'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bash ca-certificates coreutils curl file findutils grep jq less \
  openssh-client procps openscap-scanner libxml2-utils tar unzip xz-utils
rm -rf /var/lib/apt/lists/*
'@

$findProfile = @'
#!/usr/bin/env bash
set -euo pipefail
DS="/opt/ssg/ssg-ubuntu2404-ds.xml"
oscap info "$DS" 2>/dev/null | awk '/^[[:space:]]*Id:[[:space:]].*cis_level1_server/ {print $2; exit}'
'@

$audit = @'
#!/usr/bin/env bash
# Read-only OpenSCAP evidence audit. Never mutates the filesystem.
set +e
PHASE="${1:-final}"
DS="/opt/ssg/ssg-ubuntu2404-ds.xml"
PROFILE="$(/opt/hardening/find-profile.sh)"
mkdir -p /results
LOG="/results/${PHASE}-audit.log"
ARF="/results/${PHASE}-results-arf.xml"
HTML="/results/${PHASE}-report.html"

if [ -z "$PROFILE" ]; then
  echo "CIS Level 1 Server profile not found" > "$LOG"
  echo "99" > "/results/${PHASE}-audit-exit-code.txt"
  exit 0
fi

echo "Profile: $PROFILE" > "$LOG"
oscap xccdf eval --profile "$PROFILE" --results-arf "$ARF" --report "$HTML" "$DS" >> "$LOG" 2>&1
echo "$?" > "/results/${PHASE}-audit-exit-code.txt"
exit 0
'@

$hardenOpenScap = @'
#!/usr/bin/env bash
# POC self-hardening: OpenSCAP automatic remediation against cis_level1_server.
set +e
mkdir -p /results
DS="/opt/ssg/ssg-ubuntu2404-ds.xml"
PROFILE="$(/opt/hardening/find-profile.sh)"
LOG="/results/openscap-remediation.log"

if [ -z "$PROFILE" ]; then
  echo "CIS Level 1 Server profile not found" | tee "$LOG"
  echo "99" > /results/remediation-exit-code.txt
  exit 99
fi

echo "OpenSCAP self-hardening" | tee "$LOG"
echo "Profile: $PROFILE" | tee -a "$LOG"
echo "Started: $(date -Iseconds)" | tee -a "$LOG"

oscap xccdf eval --profile "$PROFILE" \
  --results /results/before-results.xml --report /results/before-report.html \
  "$DS" >> "$LOG" 2>&1
echo "$?" > /results/baseline-audit-exit-code.txt

oscap xccdf generate fix --fix-type bash --profile "$PROFILE" "$DS" \
  > /results/generated-full-profile-fix.sh 2>> "$LOG"
fixgen_rc=$?
if [[ "$fixgen_rc" -ne 0 ]]; then
  echo "OpenSCAP fix generation failed with exit code: $fixgen_rc" | tee -a "$LOG"
  exit "$fixgen_rc"
fi

oscap xccdf eval --remediate --profile "$PROFILE" \
  --results-arf /results/remediation-results-arf.xml \
  --report /results/remediation-report.html \
  "$DS" >> "$LOG" 2>&1
rem_rc=$?
echo "$rem_rc" > /results/remediation-exit-code.txt

oscap xccdf eval --profile "$PROFILE" \
  --results-arf /results/after-results-arf.xml \
  --report /results/after-report.html \
  "$DS" >> "$LOG" 2>&1
audit_rc=$?
echo "$audit_rc" > /results/post-audit-exit-code.txt

echo "Finished: $(date -Iseconds)" | tee -a "$LOG"
echo "Remediation exit code: $rem_rc" | tee -a "$LOG"
echo "Post-remediation audit exit code: $audit_rc" | tee -a "$LOG"
if [[ "$rem_rc" -ne 0 && "$rem_rc" -ne 2 ]]; then exit "$rem_rc"; fi
if [[ "$audit_rc" -ne 0 && "$audit_rc" -ne 2 ]]; then exit "$audit_rc"; fi
exit 0
'@

$hardenUsg = @'
#!/usr/bin/env bash
# Production hardening: Ubuntu Pro / USG fix against cis_level1_server.
set +e
mkdir -p /results
LOG="/results/usg-fix.log"

echo "USG CIS Level 1 Server hardening" | tee "$LOG"
echo "Started: $(date -Iseconds)" | tee -a "$LOG"

usg audit cis_level1_server >> "$LOG" 2>&1
echo "$?" > /results/baseline-audit-exit-code.txt

echo "" | tee -a "$LOG"
echo "Running: usg fix cis_level1_server" | tee -a "$LOG"
usg fix cis_level1_server >> "$LOG" 2>&1
fix_rc=$?
echo "$fix_rc" > /results/fix-exit-code.txt

echo "" | tee -a "$LOG"
echo "Post-fix audit" | tee -a "$LOG"
usg audit cis_level1_server >> "$LOG" 2>&1
audit_rc=$?
echo "$audit_rc" > /results/post-audit-exit-code.txt

if [ -d /var/lib/usg ]; then
  mkdir -p /results/usg-reports
  cp -a /var/lib/usg/. /results/usg-reports/ 2>/dev/null
fi

echo "Finished: $(date -Iseconds)" | tee -a "$LOG"
echo "USG fix exit code: $fix_rc" | tee -a "$LOG"
echo "USG post audit exit code: $audit_rc" | tee -a "$LOG"
# A failed USG remediation command is a build failure. The post-audit result is
# evidence only; container-inapplicable host rules are handled by the separate
# release compliance gate and approved tailoring process.
if [[ "$fix_rc" -ne 0 ]]; then exit "$fix_rc"; fi
exit 0
'@

$cleanupToolchain = @'
#!/usr/bin/env bash
# Strips the hardening/scanning toolchain out of the FINAL committed image.
set -e
apt-get purge -y --auto-remove openscap-scanner libxml2-utils ubuntu-pro-client usg usg-benchmarks-1 2>/dev/null || true
rm -rf /opt/hardening /opt/ssg /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/locale/* 2>/dev/null || true
exit 0
'@

$dockerCommon = @"
FROM $SourceImage
ENV DEBIAN_FRONTEND=noninteractive
COPY install-common.sh /opt/hardening/install-common.sh
RUN chmod +x /opt/hardening/install-common.sh && /opt/hardening/install-common.sh
COPY ssg-ubuntu2404-ds.xml /opt/ssg/ssg-ubuntu2404-ds.xml
COPY find-profile.sh /opt/hardening/find-profile.sh
COPY audit.sh /opt/hardening/audit.sh
COPY harden-openscap.sh /opt/hardening/harden-openscap.sh
COPY harden-usg.sh /opt/hardening/harden-usg.sh
RUN chmod +x /opt/hardening/*.sh
WORKDIR /
CMD ["sleep", "infinity"]
"@

$dockerProduction = @'
# syntax=docker/dockerfile:1.7
FROM ai-sandbox-hardening-common:build
RUN --mount=type=secret,id=pro-attach-config \
    bash -euxo pipefail -c '\
      apt-get update; \
      apt-get install -y --no-install-recommends ubuntu-pro-client ca-certificates; \
      pro attach --attach-config /run/secrets/pro-attach-config; \
      pro enable usg; \
      apt-get update; \
      apt-get install -y --no-install-recommends usg usg-benchmarks-1; \
      pro detach --assume-yes; \
      rm -rf /var/lib/apt/lists/*'
WORKDIR /
CMD ["sleep", "infinity"]
'@

Write-Utf8NoBom (Join-Path $Ctx "install-common.sh") $installCommon
Write-Utf8NoBom (Join-Path $Ctx "find-profile.sh") $findProfile
Write-Utf8NoBom (Join-Path $Ctx "audit.sh") $audit
Write-Utf8NoBom (Join-Path $Ctx "harden-openscap.sh") $hardenOpenScap
Write-Utf8NoBom (Join-Path $Ctx "harden-usg.sh") $hardenUsg
Write-Utf8NoBom (Join-Path $Ctx "cleanup-toolchain.sh") $cleanupToolchain
Write-Utf8NoBom (Join-Path $Ctx "Dockerfile.common") $dockerCommon
Write-Utf8NoBom (Join-Path $Ctx "Dockerfile.production") $dockerProduction

# ---------------------------------------------------------------------------
# Build common + raw candidate image
# ---------------------------------------------------------------------------
$env:DOCKER_BUILDKIT = "1"

Write-Step "Building common base (OS + OpenSCAP scanner + pinned SSG content)"
Invoke-Docker -Arguments @(
    "build", "--progress=plain",
    "-f", (Join-Path $Ctx "Dockerfile.common"),
    "-t", $CommonImage, $Ctx
) | Out-Null

$secretFile = $null
try {
    if ($SandboxTypeLower -eq "poc") {
        Write-Step "Building POC raw candidate (no Ubuntu Pro dependency)"
        Invoke-Docker -Arguments @(
            "build", "--progress=plain",
            "-f", (Join-Path $Ctx "Dockerfile.common"),
            "-t", $RawImage, $Ctx
        ) | Out-Null
    }
    else {
        Write-Step "Building Production raw candidate (Ubuntu Pro attach + USG install)"
        $secretFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ubuntu-pro-" + [guid]::NewGuid().ToString("N") + ".yaml")
        Write-Utf8NoBom $secretFile @"
token: $UbuntuProToken
enable_services:
  - usg
"@
        Invoke-Docker -Arguments @(
            "build", "--progress=plain",
            "--secret", "id=pro-attach-config,src=$secretFile",
            "-f", (Join-Path $Ctx "Dockerfile.production"),
            "-t", $RawImage, $Ctx
        ) | Out-Null
    }

    # -----------------------------------------------------------------------
    # Harden, audit, and commit
    # -----------------------------------------------------------------------
    & docker rm -f $BuildContainer 2>$null | Out-Null
    Invoke-Docker -Arguments @("run", "-d", "--name", $BuildContainer, $RawImage) | Out-Null

    Write-Step "Applying hardening ($SandboxTypeLower)"
    if ($SandboxTypeLower -eq "poc") {
        Invoke-Docker -Arguments @("exec", $BuildContainer, "bash", "/opt/hardening/harden-openscap.sh") | Out-Null
    }
    else {
        Invoke-Docker -Arguments @("exec", $BuildContainer, "bash", "/opt/hardening/harden-usg.sh") | Out-Null
    }

    Write-Step "Running final read-only OpenSCAP evidence audit"
    Invoke-Docker -Arguments @("exec", $BuildContainer, "bash", "/opt/hardening/audit.sh", "final") -IgnoreExitCode | Out-Null
    Invoke-Docker -Arguments @("cp", "${BuildContainer}:/results/.", (Join-Path $WorkDir "results")) -IgnoreExitCode | Out-Null

    Write-Step "Stripping the scanning/hardening toolchain from the final image"
    Invoke-Docker -Arguments @("cp", (Join-Path $Ctx "cleanup-toolchain.sh"), "${BuildContainer}:/tmp/cleanup-toolchain.sh") | Out-Null
    Invoke-Docker -Arguments @(
        "exec", $BuildContainer, "bash", "-c",
        "chmod +x /tmp/cleanup-toolchain.sh && /tmp/cleanup-toolchain.sh && rm -f /tmp/cleanup-toolchain.sh"
    ) | Out-Null

    Write-Step "Committing hardened filesystem -> ${ImageRepoName}:${Tag}"
    Invoke-Docker -Arguments @(
        "commit",
        "--change", 'CMD ["sleep", "infinity"]',
        "--change", "LABEL hardening.method=$SandboxTypeLower hardening.profile=cis_level1_server hardening.date=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        $BuildContainer, "${ImageRepoName}:${Tag}"
    ) | Out-Null

    # -----------------------------------------------------------------------
    # Push and resolve a real registry digest
    # -----------------------------------------------------------------------
    $finalRef = ""
    $digest = ""

    if ($SkipPush) {
        Write-Step "SkipPush set: image left local-only as ${ImageRepoName}:${Tag}"
        Write-Warning "This image has NO registry digest and cannot be used as BASE_IMAGE / SQUID_BASE_IMAGE (digest pin required)."
        $finalRef = "${ImageRepoName}:${Tag}"
    }
    else {
        if (-not $Registry) {
            Write-Step "No -Registry given: starting an admin-host-only digest resolution scratch registry"
            Write-Warning "Not a distribution channel. Developers never see or use this; it only exists to satisfy .build.env's digest-pinning check. The actual POC hand-off is still the unchanged tar export/load flow."
            $running = & docker ps --format '{{.Names}}' | Select-String -SimpleMatch $LocalRegistryName
            if (-not $running) {
                & docker rm -f $LocalRegistryName 2>$null | Out-Null
                Invoke-Docker -Arguments @("run", "-d", "--name", $LocalRegistryName, "-p", "${LocalRegistryPort}:5000", "registry:2") | Out-Null
                Start-Sleep -Seconds 2
            }
            $Registry = "localhost:$LocalRegistryPort"
        }

        $finalRef = "$Registry/${ImageRepoName}:${Tag}"
        Write-Step "Tagging and pushing: $finalRef"
        Invoke-Docker -Arguments @("tag", "${ImageRepoName}:${Tag}", $finalRef) | Out-Null
        Invoke-Docker -Arguments @("push", $finalRef) | Out-Null

        # Match the Bash version exactly: a FAILING `docker image inspect`
        # (e.g. the local manifest list is not yet materialised right after
        # push) must NOT abort the script — fall through to the buildx
        # imagetools fallback instead. Get-DockerText would throw on a
        # non-zero exit code, so raw invocations with 2>$null are used here.
        $repoDigestsRaw = (& docker image inspect $finalRef --format '{{index .RepoDigests 0}}' 2>$null | Out-String).Trim()
        if ($repoDigestsRaw -match '@(sha256:[0-9a-f]+)$') {
            $digest = $Matches[1]
        }
        if (-not $digest) {
            $imagetoolsRaw = (& docker buildx imagetools inspect $finalRef --format '{{json .Manifest.Digest}}' 2>$null | Out-String).Trim()
            $digest = $imagetoolsRaw.Trim('"')
        }
        if (-not $digest) {
            throw "Could not resolve a registry digest for $finalRef after push."
        }
    }

    # -----------------------------------------------------------------------
    # Emit ready-to-paste .build.env lines
    # -----------------------------------------------------------------------
    $envOut = Join-Path $WorkDir "hardened-base.env"
    if ($digest) {
        # Strip only the trailing ":<tag>" (last colon), NOT the registry's
        # own "host:port" colon — e.g. "localhost:5000/repo:tag" must become
        # "localhost:5000/repo", not "localhost".
        $lastColon = $finalRef.LastIndexOf(":")
        $repoOnly = $finalRef.Substring(0, $lastColon)
        $pinnedRef = "$repoOnly@$digest"
        Write-Utf8NoBom $envOut @"
# Generated by build-hardened-base.ps1 - sandbox type: $SandboxTypeLower
BASE_IMAGE=$pinnedRef
SQUID_BASE_IMAGE=$pinnedRef
"@
    }
    else {
        Write-Utf8NoBom $envOut @"
# -SkipPush was used - no digest available. Push to a registry and re-run
# without -SkipPush before updating .build.env.
# local image: ${ImageRepoName}:${Tag}
"@
    }

    Write-Step "DONE"
    Write-Host "  Hardened image : ${ImageRepoName}:${Tag}"
    if ($digest) { Write-Host "  Pushed ref     : $pinnedRef" -ForegroundColor Green }
    Write-Host "  Evidence dir   : $(Join-Path $WorkDir 'results')"
    Write-Host "  Env snippet    : $envOut"
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Review $(Join-Path $WorkDir 'results') (final-report.html, final-*.log)."
    Write-Host "  2. Copy the two lines from $envOut into .build.env (replacing the"
    Write-Host "     existing BASE_IMAGE / SQUID_BASE_IMAGE values)."
    Write-Host "  3. Run: .\scripts\poc\build-and-export.ps1"
}
finally {
    if (-not $KeepContainers) {
        & docker rm -f $BuildContainer 2>$null | Out-Null
    }
    if ($secretFile -and (Test-Path $secretFile)) {
        Remove-Item -Force $secretFile -ErrorAction SilentlyContinue
    }
    $UbuntuProToken = $null
}
