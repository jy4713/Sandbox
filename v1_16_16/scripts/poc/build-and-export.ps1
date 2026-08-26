#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Admin POC build workflow for the two sandbox images: DevContainer and Squid.
# Admin maintenance: Update only when the approved image set or POC bundle format changes.
# Safety rule: keep runtime policy hashes and image IDs synchronized with the delivered bundle.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
[CmdletBinding()]
param(
    [switch]$SkipCisAssessment
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Root
$B=& (Join-Path $Root 'scripts\common\Load-BuildEnv.ps1')
$BuildDate=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$GitCommit=(& git -C $Root rev-parse --short HEAD 2>$null); if(-not $GitCommit){$GitCommit='unknown'}
$Target=$B['DEVCONTAINER_TARGET']; $Version=$B['SANDBOX_VERSION']
if($B['BASE_IMAGE'] -ne $B['SQUID_BASE_IMAGE']){throw 'BASE_IMAGE and SQUID_BASE_IMAGE must be identical hardened digests'}
$ImagesDir=Join-Path $Root 'poc\images'
Remove-Item $ImagesDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $ImagesDir 'security') | Out-Null

Write-Host '=== POC Build, Assess & Export (DevContainer + Squid) ===' -ForegroundColor Cyan
$DevArgs=@(
 '--build-arg',"BASE_IMAGE=$($B['BASE_IMAGE'])", '--build-arg',"NODE_IMAGE=$($B['NODE_IMAGE'])",
 '--build-arg',"BUILD_DATE=$BuildDate", '--build-arg',"GIT_COMMIT=$GitCommit", '--build-arg',"SANDBOX_VERSION=$Version",
 '--build-arg',"CLAUDE_CODE_VERSION=$($B['CLAUDE_CODE_VERSION'])", '--build-arg',"GEMINI_CLI_VERSION=$($B['GEMINI_CLI_VERSION'])",
 '--build-arg',"TAVILY_CLI_VERSION=$($B['TAVILY_CLI_VERSION'])", '--build-arg',"TAVILY_MCP_VERSION=$($B['TAVILY_MCP_VERSION'])", '--build-arg',"MCP_REMOTE_VERSION=$($B['MCP_REMOTE_VERSION'])", '--build-arg',"SNYK_CLI_VERSION=$($B['SNYK_CLI_VERSION'])",
 '--build-arg',"NPM_REGISTRY=$($B['NPM_REGISTRY'])", '--build-arg',"AWSCLI_URL=$($B['AWSCLI_URL'])", '--build-arg',"AWSCLI_SHA256=$($B['AWSCLI_SHA256'])",
 '--build-arg',"DATABRICKS_CLI_VERSION=$($B['DATABRICKS_CLI_VERSION'])", '--build-arg',"DATABRICKS_CLI_URL=$($B['DATABRICKS_CLI_URL'])", '--build-arg',"DATABRICKS_CLI_SHA256=$($B['DATABRICKS_CLI_SHA256'])",
 '--build-arg',"UCODE_GIT_REF=$($B['UCODE_GIT_REF'])", '--build-arg',"GCM_VERSION=$($B['GCM_VERSION'])", '--build-arg',"GCM_SHA256=$($B['GCM_SHA256'])"
)
Write-Host '[1/4] Building devcontainer...' -ForegroundColor Yellow
& docker build --no-cache -f (Join-Path $Root '.devcontainer\Dockerfile') --target $Target @DevArgs -t sandbox/devcontainer:v1 $Root
if($LASTEXITCODE -ne 0){throw 'devcontainer build failed'}

if ($SkipCisAssessment) {
    Write-Warning '[2/4] CIS/OpenSCAP assessment SKIPPED for POC fast iteration.'
    $SkipNotice = @(
        'CIS_ASSESSMENT_SKIPPED=true',
        "SANDBOX_VERSION=$Version",
        "BUILD_DATE=$BuildDate",
        'REASON=POC fast iteration requested with -SkipCisAssessment',
        'SECURITY_EVIDENCE_VALID=false'
    )
    [IO.File]::WriteAllLines((Join-Path $ImagesDir 'security\CIS-ASSESSMENT-SKIPPED.txt'), $SkipNotice, [Text.ASCIIEncoding]::new())
}
else {
    Write-Host '[2/4] Assessing final devcontainer with OpenSCAP...' -ForegroundColor Yellow
    $env:CIS_REPORT_DIR=Join-Path $Root 'security\reports'; $env:REQUIRE_CIS_PASS=$B['REQUIRE_CIS_PASS']
    & (Join-Path $Root 'scripts\security\assess-cis-l1.ps1') -Image sandbox/devcontainer:v1 -ReportDir $env:CIS_REPORT_DIR
    if($LASTEXITCODE -ne 0){throw 'CIS assessment failed'}
    Copy-Item (Join-Path $env:CIS_REPORT_DIR '*') (Join-Path $ImagesDir 'security') -Force
    Copy-Item (Join-Path $Root 'security\CIS-TAILORING-README.md') (Join-Path $ImagesDir 'security') -Force
    $Tailoring=Join-Path $Root 'security\cis-tailoring.xml'; if(Test-Path $Tailoring){Copy-Item $Tailoring (Join-Path $ImagesDir 'security') -Force}
}

Write-Host '[3/4] Building Squid...' -ForegroundColor Yellow
& docker build --no-cache -f (Join-Path $Root 'squid\Dockerfile') --build-arg "BASE_IMAGE=$($B['SQUID_BASE_IMAGE'])" --build-arg "BUILD_DATE=$BuildDate" -t sandbox/squid:v1 (Join-Path $Root 'squid')
if($LASTEXITCODE -ne 0){throw 'Squid build failed'}

Write-Host '[4/4] Exporting images and integrity metadata...' -ForegroundColor Yellow
& docker save sandbox/devcontainer:v1 -o (Join-Path $ImagesDir 'sandbox-devcontainer.tar'); if($LASTEXITCODE -ne 0){throw 'docker save devcontainer failed'}
& docker save sandbox/squid:v1 -o (Join-Path $ImagesDir 'sandbox-squid.tar'); if($LASTEXITCODE -ne 0){throw 'docker save squid failed'}
$DevId=(& docker image inspect sandbox/devcontainer:v1 --format '{{.Id}}').Trim()
$SquId=(& docker image inspect sandbox/squid:v1 --format '{{.Id}}').Trim()
@("SANDBOX_VERSION=$Version","DEVCONTAINER_TAG=sandbox/devcontainer:v1","DEVCONTAINER_ID=$DevId","SQUID_TAG=sandbox/squid:v1","SQUID_ID=$SquId") | Set-Content (Join-Path $ImagesDir 'image-manifest.env') -Encoding ASCII
$Manifest=[ordered]@{sandboxVersion=$Version;buildDate=$BuildDate;gitCommit=$GitCommit;target=$Target;cisAssessmentSkipped=[bool]$SkipCisAssessment;baseImage=$B['BASE_IMAGE'];nodeImage=$B['NODE_IMAGE'];claudeCodeVersion=$B['CLAUDE_CODE_VERSION'];geminiCliVersion=$B['GEMINI_CLI_VERSION'];tavilyCliVersion=$B['TAVILY_CLI_VERSION'];tavilyMcpVersion=$B['TAVILY_MCP_VERSION'];mcpRemoteVersion=$B['MCP_REMOTE_VERSION'];snykCliVersion=$B['SNYK_CLI_VERSION'];databricksCliVersion=$B['DATABRICKS_CLI_VERSION'];ucodeGitRef=$B['UCODE_GIT_REF'];cisProfile=$B['CIS_PROFILE_ID'];ssgVersion=$B['SSG_VERSION'];images=[ordered]@{devcontainer=[ordered]@{tag='sandbox/devcontainer:v1';id=$DevId};squid=[ordered]@{tag='sandbox/squid:v1';id=$SquId}}}
[IO.File]::WriteAllText((Join-Path $ImagesDir 'image-manifest.json'),($Manifest|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$PolicyLines=@()
foreach($rel in @('.devcontainer/devcontainer.json','poc/docker-compose.yml')){$path=Join-Path $Root ($rel -replace '/', '\');if(-not(Test-Path $path)){throw "Runtime policy file missing: $rel"};$PolicyLines += "$((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant())  $rel"}
[IO.File]::WriteAllLines((Join-Path $ImagesDir 'runtime-policy.sha256'),$PolicyLines,[Text.ASCIIEncoding]::new())
$HashLines=@(); Get-ChildItem $ImagesDir -Recurse -File | Where-Object{$_.Name -ne 'SHA256SUMS'} | Sort-Object FullName | ForEach-Object{$rel=$_.FullName.Substring($ImagesDir.Length).TrimStart('\','/').Replace('\','/');$HashLines += "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  ./$rel"}
[IO.File]::WriteAllLines((Join-Path $ImagesDir 'SHA256SUMS'),$HashLines,[Text.ASCIIEncoding]::new())
Write-Host "[OK] POC two-image bundle created under $ImagesDir" -ForegroundColor Green
