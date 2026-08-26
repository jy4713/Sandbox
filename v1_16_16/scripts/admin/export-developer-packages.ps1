#Requires -Version 7.4
# =============================================================================
# ADMIN ONLY - Export minimal POC and Production Developer runtime packages.
# Documentation is optional and is not required by this export workflow.
# =============================================================================
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$IncludePocImages
)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(-not $OutputDirectory){$OutputDirectory=Join-Path $Root 'developer-packages'}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Copy-Required([string]$Source,[string]$Destination){
    if(-not(Test-Path $Source)){throw "Required source missing: $Source"}
    $Parent=Split-Path -Parent $Destination
    if($Parent){New-Item -ItemType Directory -Force -Path $Parent|Out-Null}
    Copy-Item $Source $Destination -Recurse -Force
}

function Set-DeveloperSsoDefaults([string]$TargetEnv){
    $BuildEnvPath=Join-Path $Root '.build.env'
    if(-not(Test-Path $BuildEnvPath) -or -not(Test-Path $TargetEnv)){return}
    $Vals=@{}
    Get-Content $BuildEnvPath -Encoding UTF8 | ForEach-Object {
        $line=$_.Trim()
        if($line -and -not $line.StartsWith('#') -and $line.IndexOf('=') -ge 1){
            $i=$line.IndexOf('=')
            $Vals[$line.Substring(0,$i).Trim()]=$line.Substring($i+1)
        }
    }
    $Map=[ordered]@{
        SANDBOX_AWS_PROFILE='DEVELOPER_AWS_PROFILE'; AWS_REGION='DEVELOPER_AWS_REGION';
        AWS_SSO_SESSION='DEVELOPER_AWS_SSO_SESSION'; AWS_SSO_START_URL='DEVELOPER_AWS_SSO_START_URL';
        AWS_SSO_REGION='DEVELOPER_AWS_SSO_REGION'; AWS_SSO_ACCOUNT_ID='DEVELOPER_AWS_SSO_ACCOUNT_ID';
        AWS_SSO_ROLE_NAME='DEVELOPER_AWS_SSO_ROLE_NAME'
    }
    $Lines=Get-Content $TargetEnv -Encoding UTF8
    foreach($dst in $Map.Keys){
        $src=$Map[$dst]
        if(-not $Vals[$src]){continue}
        $Lines=@($Lines | ForEach-Object {
            if($_ -match ('^'+[regex]::Escape($dst)+'=')){"$dst=$($Vals[$src])"}else{$_}
        })
    }
    [IO.File]::WriteAllLines($TargetEnv,$Lines,[Text.UTF8Encoding]::new($false))
}

$Poc=Join-Path $OutputDirectory 'AI_Sandbox_Developer_POC'
$Prod=Join-Path $OutputDirectory 'AI_Sandbox_Developer_Production'
Remove-Item $Poc,$Prod -Recurse -Force -ErrorAction SilentlyContinue

# POC
Copy-Required (Join-Path $Root '.devcontainer\devcontainer.json') (Join-Path $Poc '.devcontainer\devcontainer.json')
Copy-Required (Join-Path $Root 'poc\docker-compose.yml') (Join-Path $Poc 'poc\docker-compose.yml')
foreach($f in 'load-and-start.ps1','load-and-start.sh','verify-sandbox.ps1','verify-sandbox.sh'){
    Copy-Required (Join-Path $Root "scripts\poc\$f") (Join-Path $Poc "scripts\poc\$f")
}
Copy-Required (Join-Path $Root 'templates\developer\env.example') (Join-Path $Poc '.env.example')
Set-DeveloperSsoDefaults (Join-Path $Poc '.env.example')
Copy-Required (Join-Path $Root 'workspace\README.md') (Join-Path $Poc 'workspace\README.md')
Copy-Required (Join-Path $Root 'templates\developer\DEVELOPER-GUIDE-POC.md') (Join-Path $Poc 'DEVELOPER-GUIDE.md')
New-Item -ItemType Directory -Force -Path (Join-Path $Poc 'poc\images')|Out-Null
Set-Content (Join-Path $Poc 'poc\images\README.txt') -Value 'Admin supplies the complete generated poc/images bundle here. Do not modify bundle files.' -Encoding ASCII
if($IncludePocImages){
    $BuiltImages=Join-Path $Root 'poc\images'
    if(-not(Test-Path (Join-Path $BuiltImages 'SHA256SUMS'))){throw 'POC image bundle has not been built yet.'}
    Copy-Item (Join-Path $BuiltImages '*') (Join-Path $Poc 'poc\images') -Recurse -Force
}

# Production
Copy-Required (Join-Path $Root 'ecr\docker-compose.yml') (Join-Path $Prod 'docker-compose.yml')
Copy-Required (Join-Path $Root 'templates\developer\devcontainer-production.json') (Join-Path $Prod '.devcontainer\devcontainer.json')
foreach($f in 'pull-and-start.ps1','pull-and-start.sh'){
    Copy-Required (Join-Path $Root "scripts\ecr\$f") (Join-Path $Prod "scripts\ecr\$f")
}
Copy-Required (Join-Path $Root 'templates\developer\env.example') (Join-Path $Prod '.env.example')
Set-DeveloperSsoDefaults (Join-Path $Prod '.env.example')
Copy-Required (Join-Path $Root 'workspace\README.md') (Join-Path $Prod 'workspace\README.md')
Copy-Required (Join-Path $Root 'templates\developer\DEVELOPER-GUIDE-PRODUCTION.md') (Join-Path $Prod 'DEVELOPER-GUIDE.md')

Write-Host "[OK] POC Developer package: $Poc" -ForegroundColor Green
Write-Host "[OK] Production Developer package: $Prod" -ForegroundColor Green
