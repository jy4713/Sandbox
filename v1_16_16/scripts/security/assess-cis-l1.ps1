#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Admin offline CIS Level 1 evidence scan of the final devcontainer image using pinned OpenSCAP content.
# Admin maintenance: Application changes should not alter this script unless they require an approved CIS tailoring change or assessment workflow change.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
<#
.SYNOPSIS
  ADMIN side, CIS Level-1 assessment of the FINAL devcontainer image.
  Windows equivalent of assess-cis-l1.sh.

.DESCRIPTION
  Produces independent hardening EVIDENCE for the final devcontainer
  image by scanning its exported root filesystem offline with OpenSCAP
  and the pinned ComplianceAsCode (SSG) Ubuntu 24.04 data stream, using
  the cis_level1_server profile. Assessment evidence only - NOT CIS
  certification and NOT a CIS-CAT scan.

  Windows-safe implementation: the Linux root filesystem is never
  extracted onto NTFS. The image is exported to a temporary TAR, then a
  short-lived Linux helper container extracts that TAR into a temporary
  Docker volume. The OpenSCAP scanner mounts the volume read-only at
  /target. This preserves Linux symlinks and filesystem semantics that
  Windows tar.exe / NTFS cannot represent correctly.

  Gating: oscap exit 0 = PASS; exit 2 = rule failures (fatal only when
  REQUIRE_CIS_PASS=true in .build.env, otherwise a warning); any other
  exit = operational failure, always fatal.
#>
[CmdletBinding()]
param(
    [string]$Image = 'sandbox/devcontainer:v1',
    [string]$ReportDir
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$B = & (Join-Path $Root 'scripts\common\Load-BuildEnv.ps1')
if (-not $ReportDir) { $ReportDir = Join-Path $Root 'security\reports' }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
@('cis-l1-report.html','cis-l1-results.xml','cis-l1-results-arf.xml','cis-scan-metadata.txt') | ForEach-Object {
    Remove-Item (Join-Path $ReportDir $_) -Force -ErrorAction SilentlyContinue
}
$Version = $B['SANDBOX_VERSION']; if (-not $Version) { $Version = 'v1.16.16' }
$Profile = $B['CIS_PROFILE_ID']; if (-not $Profile) { $Profile = 'xccdf_org.ssgproject.content_profile_cis_level1_server' }
$RequirePass = ($B['REQUIRE_CIS_PASS'] -eq 'true')
$ScannerImage = "sandbox/cis-scanner:$Version"

Write-Host '[cis] Building pinned OpenSCAP scanner...' -ForegroundColor Cyan
& docker build --no-cache -f (Join-Path $Root 'security\cis-scanner\Dockerfile') `
    --build-arg "BASE_IMAGE=$($B['BASE_IMAGE'])" `
    --build-arg "SSG_URL=$($B['SSG_URL'])" `
    --build-arg "SSG_SHA256=$($B['SSG_SHA256'])" `
    -t $ScannerImage (Join-Path $Root 'security\cis-scanner')
if ($LASTEXITCODE -ne 0) { throw 'CIS scanner image build failed' }

$Info = (& docker run --rm --entrypoint oscap $ScannerImage info /opt/ssg/ssg-ubuntu2404-ds.xml 2>$null | Out-String)
if ($Info -notmatch [regex]::Escape($Profile)) {
    Write-Host ($Info -split "`n" | Where-Object { $_ -match 'cis' } | Out-String) -ForegroundColor Yellow
    throw "CIS profile '$Profile' was not found in pinned SSG content"
}

$Cid = $null
$VolumeName = $null
$TarPath = Join-Path ([IO.Path]::GetTempPath()) ('ai-sandbox-rootfs-' + [guid]::NewGuid().ToString('N') + '.tar')
try {
    $Cid = (& docker create $Image).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $Cid) { throw "Cannot create temporary container from $Image" }

    Write-Host '[cis] Exporting final Golden Image root filesystem...' -ForegroundColor Cyan
    & docker export $Cid -o $TarPath
    if ($LASTEXITCODE -ne 0) { throw 'docker export failed' }

    $VolumeName = 'ai-sandbox-cis-rootfs-' + [guid]::NewGuid().ToString('N')
    & docker volume create $VolumeName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'temporary Docker volume creation failed' }

    Write-Host '[cis] Extracting root filesystem inside Linux Docker storage...' -ForegroundColor Cyan
    $TarMount = "$($TarPath):/tmp/rootfs.tar:ro"
    $VolumeMount = "$($VolumeName):/target"
    & docker run --rm `
        -v $VolumeMount `
        -v $TarMount `
        --entrypoint /bin/sh `
        $ScannerImage `
        -c 'set -eu; tar -xf /tmp/rootfs.tar -C /target'
    if ($LASTEXITCODE -ne 0) { throw 'Linux rootfs extraction into temporary Docker volume failed' }

    $DockerArgs = @('run','--rm','-e','OSCAP_PROBE_ROOT=/target','-v',"${VolumeName}:/target:ro",'-v',"${ReportDir}:/reports")
    $OscapArgs = @('xccdf','eval','--profile',$Profile,'--results','/reports/cis-l1-results.xml','--results-arf','/reports/cis-l1-results-arf.xml','--report','/reports/cis-l1-report.html')
    $Tailoring = Join-Path $Root 'security\cis-tailoring.xml'
    if (Test-Path $Tailoring) {
        $DockerArgs += @('-v',"${Tailoring}:/tailoring.xml:ro")
        $OscapArgs += @('--tailoring-file','/tailoring.xml')
    }
    $OscapArgs += '/opt/ssg/ssg-ubuntu2404-ds.xml'

    & docker @DockerArgs $ScannerImage @OscapArgs
    $Rc = $LASTEXITCODE

    $ImageId = (& docker image inspect $Image --format '{{.Id}}').Trim()
    @(
        "sandbox_version=$Version"
        "image=$Image"
        "image_id=$ImageId"
        "profile=$Profile"
        "ssg_version=$($B['SSG_VERSION'])"
        'assessment_engine=OpenSCAP'
        'assessment_content=ComplianceAsCode'
        'assessment_scope=offline exported container root filesystem in temporary Docker volume'
        "scanner_exit_code=$Rc"
        "require_cis_pass=$($RequirePass.ToString().ToLowerInvariant())"
        "scan_time_utc=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    ) | Set-Content -Path (Join-Path $ReportDir 'cis-scan-metadata.txt') -Encoding ASCII

    if ($Rc -eq 2 -and $RequirePass) { throw 'OpenSCAP found selected-rule failures and REQUIRE_CIS_PASS=true' }
    if ($Rc -notin @(0,2)) { throw "OpenSCAP assessment failed operationally (exit $Rc)" }
    if ($Rc -eq 2) { Write-Warning 'OpenSCAP completed with selected-rule failures. Review report/tailoring before release.' }

    foreach ($Name in @('cis-l1-report.html','cis-l1-results.xml','cis-l1-results-arf.xml')) {
        $P = Join-Path $ReportDir $Name
        if (-not (Test-Path $P) -or (Get-Item $P).Length -eq 0) { throw "$Name was not generated" }
    }
}
finally {
    if ($Cid) { & docker rm -f $Cid 2>$null | Out-Null }
    if ($VolumeName) { & docker volume rm -f $VolumeName 2>$null | Out-Null }
    Remove-Item $TarPath -Force -ErrorAction SilentlyContinue
}
