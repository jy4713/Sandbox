#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose:
#   Production build/push engine for the two approved runtime images:
#     - DevContainer
#     - Squid Proxy
#
# Logging:
#   Host logging is external to the image set. This script never builds or
#   publishes a monitoring container.
#
# Approved manifest:
#   After pushing immutable image tags, this script resolves exact ECR digests,
#   writes ecr/approved-images.json, and optionally publishes that manifest and
#   its SHA-256 to AWS SSM for Developer pull-and-start.
# =============================================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Build = & (Join-Path $Root 'scripts\common\Load-BuildEnv.ps1')

$EcrRegistry = $env:ECR_REGISTRY
if (-not $EcrRegistry) { throw 'Set ECR_REGISTRY before running the Production build' }
$EcrRegistry = $EcrRegistry.TrimEnd('/')
$Region = if ($env:AWS_REGION) { $env:AWS_REGION } else { 'eu-west-2' }
$ReleaseTag = $Build['RELEASE_TAG']
$BuildDate = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$GitCommit = (& git -C $Root rev-parse --short HEAD 2>$null)
if (-not $GitCommit) { $GitCommit = 'unknown' }

if ($Build['BASE_IMAGE'] -ne $Build['SQUID_BASE_IMAGE']) {
    throw 'BASE_IMAGE and SQUID_BASE_IMAGE must be the same hardened digest'
}

Write-Host '=== Production ECR Build (DevContainer + Squid) ===' -ForegroundColor Cyan

# Authenticate Docker to the target ECR registry using the current Admin AWS
# identity/profile. AWS_PROFILE can be provided by the calling environment.
$Password = & aws ecr get-login-password --region $Region
if ($LASTEXITCODE -ne 0) { throw 'Unable to obtain ECR login password' }
$Password | docker login --username AWS --password-stdin $EcrRegistry | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker ECR login failed' }

# Ensure the two runtime repositories exist and are immutable/scanned on push.
$Repositories = @('ai-sandbox/devcontainer', 'ai-sandbox/squid')
foreach ($Repository in $Repositories) {
    & aws ecr describe-repositories --repository-names $Repository --region $Region 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & aws ecr create-repository `
            --repository-name $Repository `
            --image-tag-mutability IMMUTABLE `
            --image-scanning-configuration scanOnPush=true `
            --region $Region | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to create ECR repository: $Repository" }
    }
    else {
        & aws ecr put-image-tag-mutability `
            --repository-name $Repository `
            --image-tag-mutability IMMUTABLE `
            --region $Region | Out-Null
        & aws ecr put-image-scanning-configuration `
            --repository-name $Repository `
            --image-scanning-configuration scanOnPush=true `
            --region $Region | Out-Null
    }
}

$DevImage = "$EcrRegistry/ai-sandbox/devcontainer:$ReleaseTag"
$SquidImage = "$EcrRegistry/ai-sandbox/squid:$ReleaseTag"

$DevBuildArgs = @(
    '--build-arg', "BASE_IMAGE=$($Build['BASE_IMAGE'])",
    '--build-arg', "NODE_IMAGE=$($Build['NODE_IMAGE'])",
    '--build-arg', "BUILD_DATE=$BuildDate",
    '--build-arg', "GIT_COMMIT=$GitCommit",
    '--build-arg', "SANDBOX_VERSION=$($Build['SANDBOX_VERSION'])",
    '--build-arg', "CLAUDE_CODE_VERSION=$($Build['CLAUDE_CODE_VERSION'])",
    '--build-arg', "GEMINI_CLI_VERSION=$($Build['GEMINI_CLI_VERSION'])",
    '--build-arg', "TAVILY_CLI_VERSION=$($Build['TAVILY_CLI_VERSION'])",
    '--build-arg', "TAVILY_MCP_VERSION=$($Build['TAVILY_MCP_VERSION'])",
    '--build-arg', "MCP_REMOTE_VERSION=$($Build['MCP_REMOTE_VERSION'])",
    '--build-arg', "SNYK_CLI_VERSION=$($Build['SNYK_CLI_VERSION'])",
    '--build-arg', "NPM_REGISTRY=$($Build['NPM_REGISTRY'])",
    '--build-arg', "AWSCLI_URL=$($Build['AWSCLI_URL'])",
    '--build-arg', "AWSCLI_SHA256=$($Build['AWSCLI_SHA256'])",
    '--build-arg', "DATABRICKS_CLI_VERSION=$($Build['DATABRICKS_CLI_VERSION'])",
    '--build-arg', "DATABRICKS_CLI_URL=$($Build['DATABRICKS_CLI_URL'])",
    '--build-arg', "DATABRICKS_CLI_SHA256=$($Build['DATABRICKS_CLI_SHA256'])",
    '--build-arg', "UCODE_GIT_REF=$($Build['UCODE_GIT_REF'])",
    '--build-arg', "GCM_VERSION=$($Build['GCM_VERSION'])",
    '--build-arg', "GCM_SHA256=$($Build['GCM_SHA256'])"
)

Write-Host '[1/4] Building DevContainer...' -ForegroundColor Yellow
& docker build --no-cache `
    -f (Join-Path $Root '.devcontainer\Dockerfile') `
    --target $Build['DEVCONTAINER_TARGET'] `
    @DevBuildArgs `
    -t $DevImage `
    $Root
if ($LASTEXITCODE -ne 0) { throw 'DevContainer build failed' }

Write-Host '[2/4] Running fail-closed CIS assessment...' -ForegroundColor Yellow
$PreviousRequireCisPass = $env:REQUIRE_CIS_PASS
try {
    $env:REQUIRE_CIS_PASS = 'true'
    & (Join-Path $Root 'scripts\security\assess-cis-l1.ps1') `
        -Image $DevImage `
        -ReportDir (Join-Path $Root 'security\reports')
    if ($LASTEXITCODE -ne 0) { throw 'CIS release gate failed' }
}
finally {
    if ($null -eq $PreviousRequireCisPass) {
        Remove-Item Env:REQUIRE_CIS_PASS -ErrorAction SilentlyContinue
    }
    else {
        $env:REQUIRE_CIS_PASS = $PreviousRequireCisPass
    }
}

Write-Host '[3/4] Building Squid...' -ForegroundColor Yellow
& docker build --no-cache `
    -f (Join-Path $Root 'squid\Dockerfile') `
    --build-arg "BASE_IMAGE=$($Build['SQUID_BASE_IMAGE'])" `
    --build-arg "BUILD_DATE=$BuildDate" `
    -t $SquidImage `
    (Join-Path $Root 'squid')
if ($LASTEXITCODE -ne 0) { throw 'Squid build failed' }

Write-Host '[4/4] Pushing approved images and publishing manifest...' -ForegroundColor Yellow
foreach ($Image in @($DevImage, $SquidImage)) {
    & docker push $Image | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Push failed: $Image" }
}

function Get-EcrDigest {
    param([Parameter(Mandatory = $true)][string]$Repository)
    $Digest = & aws ecr describe-images `
        --repository-name $Repository `
        --image-ids "imageTag=$ReleaseTag" `
        --region $Region `
        --query 'imageDetails[0].imageDigest' `
        --output text
    if ($LASTEXITCODE -ne 0 -or $Digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "Digest lookup failed: $Repository"
    }
    return $Digest.Trim()
}

$DevDigest = Get-EcrDigest -Repository 'ai-sandbox/devcontainer'
$SquidDigest = Get-EcrDigest -Repository 'ai-sandbox/squid'

$Manifest = [ordered]@{
    approvedAt     = $BuildDate
    sandboxVersion = $Build['SANDBOX_VERSION']
    releaseTag     = $ReleaseTag
    gitCommit      = $GitCommit
    registry       = $EcrRegistry
    cisEvidence    = 'security/reports/cis-l1-report.html'
    toolVersions   = [ordered]@{
        claudeCode    = $Build['CLAUDE_CODE_VERSION']
        geminiCli     = $Build['GEMINI_CLI_VERSION']
        tavilyCli     = $Build['TAVILY_CLI_VERSION']
        tavilyMcp     = $Build['TAVILY_MCP_VERSION']
        mcpRemote     = $Build['MCP_REMOTE_VERSION']
        snykCli       = $Build['SNYK_CLI_VERSION']
        databricksCli = $Build['DATABRICKS_CLI_VERSION']
        ucodeGitRef   = $Build['UCODE_GIT_REF']
    }
    images = [ordered]@{
        devcontainer = [ordered]@{
            full   = "$EcrRegistry/ai-sandbox/devcontainer@$DevDigest"
            digest = $DevDigest
        }
        squid = [ordered]@{
            full   = "$EcrRegistry/ai-sandbox/squid@$SquidDigest"
            digest = $SquidDigest
        }
    }
}

$ManifestPath = Join-Path $Root 'ecr\approved-images.json'
$ManifestJson = $Manifest | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText($ManifestPath, $ManifestJson, [Text.UTF8Encoding]::new($false))

$Publish = if ($env:PUBLISH_APPROVED_MANIFEST_TO_SSM) {
    $env:PUBLISH_APPROVED_MANIFEST_TO_SSM
}
else {
    $Build['PUBLISH_APPROVED_MANIFEST_TO_SSM']
}

if ($Publish -ne 'false') {
    $SsmPrefix = if ($env:SSM_PREFIX) {
        $env:SSM_PREFIX.TrimEnd('/')
    }
    elseif ($Build['SSM_PREFIX']) {
        $Build['SSM_PREFIX'].TrimEnd('/')
    }
    else {
        '/sandbox'
    }

    $ManifestParameter = if ($env:APPROVED_IMAGES_SSM_PARAMETER) {
        $env:APPROVED_IMAGES_SSM_PARAMETER
    }
    elseif ($Build['APPROVED_IMAGES_SSM_PARAMETER']) {
        $Build['APPROVED_IMAGES_SSM_PARAMETER']
    }
    else {
        "$SsmPrefix/runtime/approved-images-json"
    }

    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $ManifestHash = ([BitConverter]::ToString(
            $Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($ManifestJson))
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $Hasher.Dispose()
    }

    & aws ssm put-parameter `
        --name $ManifestParameter `
        --type String `
        --value $ManifestJson `
        --overwrite `
        --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to publish approved manifest to $ManifestParameter" }

    & aws ssm put-parameter `
        --name "$ManifestParameter-sha256" `
        --type String `
        --value $ManifestHash `
        --overwrite `
        --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to publish approved manifest SHA-256' }

    Write-Host "[OK] Approved manifest published to $ManifestParameter" -ForegroundColor Green
}

Write-Host "[OK] Production two-image release: $ManifestPath" -ForegroundColor Green
