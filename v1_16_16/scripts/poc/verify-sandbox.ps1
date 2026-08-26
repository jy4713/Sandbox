#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Host-side POC validation of container state, egress policy, read-only controls and expected components.
# Admin maintenance: Add/remove application checks when a new tool must be proven present or a new outbound service must be proven allowed/blocked.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
<#
.SYNOPSIS
  DEVELOPER/ADMIN side, post-start security verification.
  Windows equivalent of verify-sandbox.sh (same checks).

.DESCRIPTION
  Runs on the host (Windows 365 VM) AFTER the stack is up
  (scripts\poc\load-and-start.ps1, or the ECR equivalent) and proves that
  the sandbox actually enforces its security model. Exits with code 1 if
  any FAIL check triggers, so it can gate onboarding or CI.

  Test groups:
    1. Stack / proxy health      - Squid container healthy
    2. Host internet (informational only)
    3. Whitelisted egress        - github.com, registry.npmjs.org,
                                   dev.azure.com, login.microsoftonline.com
                                   and the Databricks workspace MUST be
                                   reachable THROUGH the Squid proxy
    4. Non-whitelisted egress    - api.anthropic.com, example.com,
                                   google.com MUST be blocked (403/407/000)
    5. True proxy bypass         - direct (no-proxy) HTTP and raw TCP to
                                   1.1.1.1:443 MUST fail (internal network)
    6. DNS-over-HTTPS            - dns.google / cloudflare-dns / quad9
                                   MUST be blocked
    7. CONNECT port restriction  - CONNECT github.com:22 MUST be blocked
    8. Container hardening       - non-root user (vscode), no sudo binary,
                                   NET_ADMIN blocked, verify-runtime passes
    9. Audit / logging           - \var\log\sandbox\audit.log exists and
                                   host-exported log files are available

.PARAMETER Path
  Selects the COMPOSE FILE to verify, not the hardening mode:
    poc (default) - poc\docker-compose.yml
    ecr           - ecr\docker-compose.yml
  The hardening mode (poc/production) was fixed at image build time.

.EXAMPLE
  pwsh -NoProfile -File scripts\poc\verify-sandbox.ps1
  pwsh -NoProfile -File scripts\poc\verify-sandbox.ps1 -Path ecr
#>
[CmdletBinding()]
param([ValidateSet('poc','ecr')][string]$Path='poc')
$ErrorActionPreference='SilentlyContinue'
$Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot); $Compose=Join-Path $Root "$Path\docker-compose.yml"
$script:Pass=0;$script:Fail=0;$script:Warn=0
function Ok([string]$m){Write-Host "  [PASS] $m" -ForegroundColor Green;$script:Pass++}
function Fail([string]$m){Write-Host "  [FAIL] $m" -ForegroundColor Red;$script:Fail++}
function Warn([string]$m){Write-Host "  [WARN] $m" -ForegroundColor Yellow;$script:Warn++}
function Dc([string[]]$DockerArgs){ & docker compose -f $Compose @DockerArgs }
function Proxy-Code([string]$Url){ $c=Dc @('exec','-T','devcontainer','sh','-c','curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -x http://squid-proxy:3128 "$1" 2>/dev/null || printf 000','sh',$Url) 2>$null; if($c){return (($c|Select-Object -Last 1).ToString().Trim() -replace '.*([0-9]{3})$','$1')}return '000' }
function Direct-Code([string]$Url){ $c=Dc @('exec','-T','devcontainer','sh','-c','env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy curl --noproxy "*" -sS -o /dev/null -w "%{http_code}" --max-time 5 "$1" 2>/dev/null || printf 000','sh',$Url) 2>$null; if($c){return (($c|Select-Object -Last 1).ToString().Trim() -replace '.*([0-9]{3})$','$1')}return '000' }

Write-Host '================================================' -ForegroundColor Cyan; Write-Host "  AI Sandbox Security Verification ($Path)" -ForegroundColor Cyan; Write-Host '================================================' -ForegroundColor Cyan
Write-Host "`n--- Stack / proxy health ---"; $ps=(Dc @('ps','squid-proxy') 2>$null | Out-String); if($ps -match 'healthy|running|Up'){Ok 'Squid proxy is running/healthy'}else{Fail 'Squid proxy is not healthy'}
Write-Host "`n--- Host machine (informational) ---"; try{$r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 https://example.com -EA Stop;if([int]$r.StatusCode -ge 200 -and [int]$r.StatusCode -lt 400){Ok "Host -> example.com ($($r.StatusCode))"}else{Warn "Host internet status $($r.StatusCode)"}}catch{Warn 'Host internet check failed'}
Write-Host "`n--- Whitelisted egress (must reach destination) ---"; foreach($url in @('https://github.com','https://registry.npmjs.org','https://dev.azure.com','https://login.microsoftonline.com','https://api.tavily.com','https://api.snyk.io')){$c=Proxy-Code $url;if($c -match '^[23][0-9]{2}$'){Ok "Container -> $url ($c)"}else{Fail "Container -> $url did not return 2xx/3xx ($c)"}}
$db=(Dc @('exec','-T','devcontainer','sh','-c','curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -x http://squid-proxy:3128 "${DATABRICKS_HOST%/}" 2>/dev/null || printf 000') 2>$null | Select-Object -Last 1).ToString().Trim(); if($db -match '([0-9]{3})$'){$db=$matches[1]}else{$db='000'}; if($db -match '^[23][0-9]{2}$'){Ok "Container -> Databricks workspace ($db)"}else{Fail "Databricks workspace not reachable through Squid ($db)"}
Write-Host "`n--- Non-whitelisted vendor/public egress (must be blocked) ---"; foreach($url in @('http://api.anthropic.com','http://example.com','http://google.com')){$c=Proxy-Code $url;if($c -in @('000','403','407')){Ok "Container -> $url BLOCKED ($c)"}else{Fail "Container -> $url reachable ($c)"}}
Write-Host "`n--- True proxy-bypass/direct egress (must be blocked) ---"; foreach($url in @('http://93.184.216.34','http://1.1.1.1')){$c=Direct-Code $url;if($c -eq '000'){Ok "Direct/no-proxy -> $url BLOCKED"}else{Fail "Direct/no-proxy -> $url reachable ($c)"}}
Dc @('exec','-T','devcontainer','bash','-c','env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy timeout 4 bash -c "</dev/tcp/1.1.1.1/443"') 2>$null | Out-Null;if($LASTEXITCODE -eq 0){Fail 'Direct TCP -> 1.1.1.1:443 reachable (proxy bypass exists)'}else{Ok 'Direct TCP -> 1.1.1.1:443 blocked'}
Write-Host "`n--- DNS over HTTPS via proxy (must be blocked) ---"; foreach($doh in @('https://dns.google/resolve?name=example.com','https://cloudflare-dns.com/dns-query','https://dns.quad9.net/dns-query')){$c=Proxy-Code $doh;$h=([uri]$doh).Host;if($c -in @('000','403','407')){Ok "DoH -> $h BLOCKED ($c)"}else{Fail "DoH -> $h reachable ($c)"}}
Write-Host "`n--- CONNECT port restriction ---";$c=Proxy-Code 'https://github.com:22';if($c -in @('000','403','407')){Ok "CONNECT github.com:22 BLOCKED ($c)"}else{Fail "CONNECT github.com:22 unexpectedly reachable ($c)"}
Write-Host "`n--- Container hardening ---";$u=(Dc @('exec','-T','devcontainer','whoami') 2>$null | Select-Object -Last 1).ToString().Trim();if($u -eq 'vscode'){Ok 'Non-root user: vscode'}else{Fail "Running as: $u"};Dc @('exec','-T','devcontainer','sh','-c','command -v sudo >/dev/null 2>&1') 2>$null|Out-Null;if($LASTEXITCODE -eq 0){Fail 'sudo binary is installed'}else{Ok 'sudo binary is absent'}
Dc @('exec','-T','devcontainer','sh','-c','command -v iptables >/dev/null 2>&1') 2>$null | Out-Null
if($LASTEXITCODE -eq 0){
 $ipt=(Dc @('exec','-T','devcontainer','iptables','-L') 2>&1 | Out-String)
 if($ipt -match 'Operation not permitted|Permission denied'){Ok 'NET_ADMIN blocked'}else{Warn 'iptables exists; verify NET_ADMIN/capabilities'}
}else{Ok 'iptables not installed'}
Dc @('exec','-T','devcontainer','bash','-lc','verify-runtime') 2>$null|Out-Null;if($LASTEXITCODE -eq 0){Ok 'verify-runtime passed'}else{Fail 'verify-runtime failed'}
Write-Host "`n--- Audit / host logging ---"
Dc @('exec','-T','devcontainer','test','-f','/var/log/sandbox/audit.log') 2>$null|Out-Null
if($LASTEXITCODE -eq 0){Ok 'audit.log exists inside devcontainer'}else{Fail 'audit.log missing inside devcontainer'}
$EnvFile=Join-Path $Root '.env'; $LogRoot=Join-Path $Root 'logs'
if(Test-Path $EnvFile){$line=Get-Content $EnvFile|Where-Object{$_ -match '^SANDBOX_LOG_ROOT='}|Select-Object -Last 1;if($line){$v=$line.Substring($line.IndexOf('=')+1);if($v){$LogRoot=$v}}}
if(-not [IO.Path]::IsPathRooted($LogRoot)){$LogRoot=Join-Path $Root $LogRoot}
$HostAudit=Join-Path $LogRoot 'devcontainer\audit.log'
if(Test-Path $HostAudit){Ok "host-visible audit log: $HostAudit"}else{Warn "host-visible audit log not found yet: $HostAudit"}
$SquidLogDir=Join-Path $LogRoot 'squid'
if(Test-Path $SquidLogDir){Ok "host-visible Squid log directory: $SquidLogDir"}else{Warn "host-visible Squid log directory not found: $SquidLogDir"}
Write-Host "`n================================================";Write-Host "  Result: $Pass passed  $Fail failed  $Warn warnings";Write-Host '================================================';if($Fail -gt 0){exit 1}
