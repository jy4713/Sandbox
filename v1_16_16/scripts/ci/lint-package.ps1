#Requires -Version 7.4
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Windows static regression checks for the v1.16.16 host-logging package.
# =============================================================================
$ErrorActionPreference='Stop';$Root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$script:Failures=0
function Pass($m){Write-Host "  [OK]   $m" -ForegroundColor Green};function Fail($m){Write-Host "  [FAIL] $m" -ForegroundColor Red;$script:Failures++}
Write-Host '=== AI Sandbox v1.16.16 package lint ===' -ForegroundColor Cyan
$Required=@(
    '.build.env.example','.env.example','.devcontainer\Dockerfile','.devcontainer\post-create.sh',
    'poc\docker-compose.yml','ecr\docker-compose.yml',
    '.devcontainer\scripts\configure-aws-sso.sh','.devcontainer\scripts\sandbox-aws-login.sh',
    '.devcontainer\scripts\sandbox-info.sh','.devcontainer\scripts\claude-audit-hook.sh',
    '.devcontainer\scripts\application-audit.sh','.devcontainer\scripts\sandbox-command-wrapper.sh',
    'scripts\poc\build-and-export.ps1','scripts\poc\load-and-start.ps1',
    'scripts\platform\02-setup-ecr.ps1','scripts\ecr\pull-and-start.ps1',
    'scripts\platform\03-setup-logging.ps1','scripts\monitoring\send-logs-ingestion.ps1',
    'scripts\monitoring\verify-host-log-export.ps1',
    'scripts\applications\add-application.ps1','scripts\applications\remove-application.ps1',
    'scripts\applications\validate-application.ps1','scripts\applications\application-helper.py',
    'templates\developer\env.example','templates\developer\devcontainer-production.json',
    'templates\developer\DEVELOPER-GUIDE-POC.md','templates\developer\DEVELOPER-GUIDE-PRODUCTION.md',
    'sentinel\dcr-ama-custom-text.example.json','sentinel\dcr-logs-ingestion.example.json'
)
foreach($f in $Required){if(Test-Path(Join-Path $Root $f)){Pass $f}else{Fail "$f missing"}}
if(Test-Path(Join-Path $Root 'fluent-bit')){Fail 'fluent-bit directory still exists'}else{Pass 'fluent-bit directory absent'}
$Active=@((Join-Path $Root 'scripts'),(Join-Path $Root 'poc'),(Join-Path $Root 'ecr'),(Join-Path $Root '.build.env.example'),(Join-Path $Root '.env.example'))
$refs=$Active|Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name-notlike'lint-package.*'}|Select-String -Pattern 'sandbox-fluent-bit|FLUENT_BIT_BASE_IMAGE|AZURE_LAW_|azure-law-(workspace-id|shared-key)' -ErrorAction SilentlyContinue
if($refs){$refs|ForEach-Object{Write-Host $_};Fail 'active Fluent Bit/shared-key references remain'}else{Pass 'no active Fluent Bit/shared-key references'}
foreach($compose in @('poc\docker-compose.yml','ecr\docker-compose.yml')){$txt=Get-Content(Join-Path $Root $compose)-Raw;if($txt-match'SANDBOX_LOG_ROOT'-and$txt-match'/var/log/sandbox'-and$txt-match'/var/log/squid'){Pass "$compose host logging"}else{Fail "$compose host logging missing"}}
$pocCompose=Get-Content (Join-Path $Root 'poc\docker-compose.yml') -Raw
if($pocCompose -match 'SANDBOX_CONTENT_LOGGING: "\$\{SANDBOX_CONTENT_LOGGING:-false\}"' -and $pocCompose -match 'GEMINI_TELEMETRY_LOG_PROMPTS: "false"'){Pass 'Content logging defaults off'}else{Fail 'Content logging default policy missing'}
$dockerfile=Get-Content (Join-Path $Root '.devcontainer\Dockerfile') -Raw

if($dockerfile -match 'vim-tiny' -and $dockerfile -match "'set nomodeline'" -and $dockerfile -match "'set noexrc'" -and $dockerfile -match "'set noswapfile'" -and $dockerfile -match 'chmod 0444 /etc/vim/vimrc.local'){Pass 'minimal vi is installed with hardened immutable configuration'}else{Fail 'secure vi/vim-tiny configuration missing'}
if($dockerfile -match '/usr/local/bin/claude-audit-hook' -and $dockerfile -match '/etc/claude-code/managed-settings.json'){Pass 'Claude managed audit hook'}else{Fail 'Claude managed audit hook missing'}
if($dockerfile -match '/usr/local/bin/application-audit'){Pass 'application-audit helper'}else{Fail 'application-audit helper missing'}
if($dockerfile -match '/usr/local/libexec/ai-sandbox/sandbox-command-wrapper'){Pass 'SSM command wrapper baked into image'}else{Fail 'SSM command wrapper missing'}
$buildOrchestrator=Get-Content (Join-Path $Root 'scripts\admin\build-sandbox.ps1') -Raw
if($buildOrchestrator -match '\[switch\]\$ReuseHardenedBase' -and $buildOrchestrator -match 'Test-ReusableHardenedBase' -and $buildOrchestrator -match 'hardening\.method' -and $buildOrchestrator -match 'hardening\.profile' -and $buildOrchestrator -match 'Falling back automatically to a new hardened-base build'){Pass 'validated hardened-base reuse with automatic full-build fallback'}else{Fail 'hardened-base reuse/fallback contract missing'}
if($buildOrchestrator -match '\[string\]\$BuildEnvSource' -and $buildOrchestrator -match 'SANDBOX_VERSION' -and $buildOrchestrator -match 'v1\.16\.5'){Pass 'previous .build.env migration and v1.16.16 stamping supported'}else{Fail 'build-env reuse migration/version stamping missing'}
$wrapper=Get-Content (Join-Path $Root '.devcontainer\scripts\sandbox-command-wrapper.sh') -Raw
if($wrapper -match '--profile anthropic' -and $wrapper -match '--profile gemini' -and $wrapper -match 'real_tool ucode' -and $wrapper -match '--profile databricks'){Pass 'direct Claude/Gemini and explicit ucode/Databricks routing are separated'}else{Fail 'AI command routing contract missing'}
$mcp=Get-Content (Join-Path $Root '.devcontainer\scripts\configure-mcp.sh') -Raw
if($mcp -match '/usr/local/bin/tavily-mcp-ssm' -and $mcp -match 'REAL_CLAUDE' -and $mcp -match 'REAL_GEMINI'){Pass 'Tavily MCP credential-value-free registration'}else{Fail 'Tavily MCP registration path incorrect'}
$runnerForMcp=Get-Content (Join-Path $Root '.devcontainer\scripts\run-with-ssm-secrets.sh') -Raw
# v1.16.16 - Gemini strips inherited sensitive variables from stdio MCP children,
# so settings must carry literal runtime references but never credential values.
if($mcp -notmatch '(?m)mcp\s+add\b.*(?:\s-e\s|\s--env\s)'){Pass 'Gemini MCP does not use CLI -e credential injection'}else{Fail 'Gemini MCP still uses command-line env injection'}
if($mcp -match 'AWS_ACCESS_KEY_ID: "\$AWS_ACCESS_KEY_ID"' -and $mcp -match 'AWS_SECRET_ACCESS_KEY: "\$AWS_SECRET_ACCESS_KEY"' -and $mcp -match 'AWS_SESSION_TOKEN: "\$AWS_SESSION_TOKEN"' -and $mcp -match 'approved AWS runtime references'){Pass 'Gemini MCP stores only approved runtime AWS references, never values'}else{Fail 'Gemini MCP runtime-reference contract missing'}
if($mcp -match 'gemini_state_home="\$\{GEMINI_CLI_HOME:-\$HOME\}"' -and $runnerForMcp -match 'GEMINI_CLI_HOME="\$ucode_gemini_cli_home"' -and $runnerForMcp -match 'from ucode.agents.gemini import GEMINI_HOME_DIR'){Pass 'direct and ucode Gemini MCP settings target correct Gemini state homes'}else{Fail 'ucode Gemini GEMINI_CLI_HOME MCP contract missing'}
if($mcp -match 'mcpServers' -and $mcp -match 'AWS access-key credential material detected'){Pass 'MCP settings written deterministically with credential-value self-check'}else{Fail 'MCP settings writer or credential self-check missing'}
$appHelper=Get-Content (Join-Path $Root 'scripts\applications\application-helper.py') -Raw
if($appHelper -match 'mcp-wrapper-preamble' -and $appHelper -match 'AWS_ACCESS_KEY_ID: "\$AWS_ACCESS_KEY_ID"' -and $appHelper -match '"\$gemini_config_dir"' -and $appHelper -notmatch '"\$REAL_GEMINI"\s+mcp\s+add'){Pass 'Admin application helper preserves the v1.16.16 Gemini MCP contract'}else{Fail 'application helper would regress Gemini MCP registration'}
$tavilyWrapper=Get-Content (Join-Path $Root '.devcontainer\scripts\tavily-mcp-ssm.sh') -Raw
$snykWrapper=Get-Content (Join-Path $Root '.devcontainer\scripts\snyk-mcp-ssm.sh') -Raw
$mcpPreamble=Join-Path $Root '.devcontainer\scripts\mcp-wrapper-preamble.sh'
if((Test-Path $mcpPreamble) -and $tavilyWrapper -match 'mcp-wrapper-preamble' -and $snykWrapper -match 'mcp-wrapper-preamble'){Pass 'MCP wrappers source the deterministic environment preamble'}else{Fail 'MCP wrapper preamble missing or not sourced'}

if($mcp -match '/usr/local/bin/databricks-sql-mcp-ssm' -and $runnerForMcp -match 'databricks-sql-mcp-token' -and $dockerfile -match 'mcp-remote@\$\{MCP_REMOTE_VERSION\}'){Pass 'Databricks SQL MCP uses dedicated SSM token and pinned bridge'}else{Fail 'Databricks SQL MCP contract missing'}
$tavilyPolicyProxy=Get-Content (Join-Path $Root '.devcontainer\scripts\tavily-policy-proxy.py') -Raw
$geminiWebPolicy=Get-Content (Join-Path $Root '.devcontainer\policies\gemini-web-policy.toml') -Raw
if($tavilyWrapper -match 'tavily-policy-proxy.py' -and $runnerForMcp -match 'unset DEFAULT_PARAMETERS' -and $dockerfile -match 'tavily-allowed-domains.json'){Pass 'Tavily MCP domain allowlist is enforced by Admin-owned proxy'}else{Fail 'Tavily hard domain policy missing'}
if($dockerfile -match '"WebSearch"' -and $geminiWebPolicy -match 'google_web_search'){Pass 'Claude/Gemini native web tools are disabled by Admin policy'}else{Fail 'Admin native-web deny policy missing'}
if($pocCompose -match 'SANDBOX_AUDIT_REQUIRED: "\$\{SANDBOX_AUDIT_REQUIRED:-true\}"'){Pass 'application audit required by default'}else{Fail 'application audit policy missing'}
$ecrCompose=Get-Content (Join-Path $Root 'ecr\docker-compose.yml') -Raw
$devcontainerJson=Get-Content (Join-Path $Root '.devcontainer\devcontainer.json') -Raw
$prodDevcontainerJson=Get-Content (Join-Path $Root 'templates\developer\devcontainer-production.json') -Raw
if($devcontainerJson -match '"workspaceFolder"\s*:\s*"/home/vscode/workspace"' -and $prodDevcontainerJson -match '"workspaceFolder"\s*:\s*"/home/vscode/workspace"' -and $pocCompose -match 'target:\s*/home/vscode/workspace' -and $ecrCompose -match 'target:\s*/home/vscode/workspace' -and $dockerfile -match 'WORKDIR /home/\$\{USERNAME\}/workspace'){Pass 'Developer workspace is mounted under /home/vscode/workspace'}else{Fail 'home-workspace contract missing'}
$legacyWorkspace=Get-ChildItem @((Join-Path $Root '.devcontainer'),(Join-Path $Root 'poc'),(Join-Path $Root 'ecr'),(Join-Path $Root 'templates\developer')) -Recurse -File -ErrorAction SilentlyContinue | Where-Object {$_.Name -notlike 'lint-package.*'} | Select-String -Pattern 'workspaceFolder"\s*:\s*"/workspace"|target:\s*/workspace(?:\s|$)|WORKDIR\s+/workspace(?:\s|$)' -ErrorAction SilentlyContinue
if($legacyWorkspace){Fail 'legacy root-level /workspace runtime path remains'}else{Pass 'legacy root-level /workspace runtime path absent'}
if($pocCompose -match 'AWS_ACCESS_KEY_ID' -and $pocCompose -match 'AWS_SECRET_ACCESS_KEY' -and $ecrCompose -match 'AWS_ACCESS_KEY_ID' -and $ecrCompose -match 'AWS_SSO_START_URL' -and $pocCompose -match 'SANDBOX_AWS_PROFILE' -and $pocCompose -notmatch '(?m)^\s*AWS_PROFILE:'){Pass 'AWS static-key and SSO fallback Compose mapping without AWS_PROFILE injection'}else{Fail 'AWS dual-mode Compose/profile isolation missing'}
$secretRunner=Get-Content (Join-Path $Root '.devcontainer\scripts\run-with-ssm-secrets.sh') -Raw
$login=Get-Content (Join-Path $Root '.devcontainer\scripts\sandbox-aws-login.sh') -Raw
$awsBootstrap=Get-Content (Join-Path $Root '.devcontainer\scripts\configure-aws-sso.sh') -Raw
if($secretRunner -match 'aws_auth_mode="static"' -and $secretRunner -match 'drop_aws_bootstrap_credentials' -and $secretRunner -match 'Tavily/Snyk MCP wrappers'){Pass 'static AWS key-first runtime flow with MCP inheritance'}else{Fail 'static AWS key-first runtime flow with MCP inheritance missing'}
if($awsBootstrap -match 'Non-secret compatibility profile for static environment credentials' -and $awsBootstrap -match '\[default\]' -and $awsBootstrap -match 'SANDBOX_AWS_PROFILE' -and $secretRunner -match 'configure-aws-sso >/dev/null'){Pass 'AWS_PROFILE is isolated from runtime while default/named AWS config is prepared'}else{Fail 'AWS profile isolation/bootstrap missing'}
if($secretRunner -match 'sandbox-aws-login' -and $login -match '--use-device-code --no-browser'){Pass 'SSO browser fallback flow'}else{Fail 'automatic SSO fallback flow missing'}
# v1.16.16 - IAM Identity Center must remain reachable from ephemeral HOME
# directories (ucode agents, Tavily/Snyk MCP), and must never prompt on stdio.
if($secretRunner -match 'SANDBOX_AWS_HOME' -and $secretRunner -match 'HOME="\$AWS_STATE_HOME" aws' -and $login -match 'SANDBOX_AWS_HOME'){Pass 'AWS CLI state pinned to a HOME-independent anchor for SSO reachability'}else{Fail 'AWS state anchor missing; SSO breaks under ephemeral HOME'}
if($secretRunner -match 'SANDBOX_NONINTERACTIVE' -and $login -match 'SANDBOX_NONINTERACTIVE'){Pass 'interactive SSO sign-in refused in MCP stdio contexts'}else{Fail 'non-interactive SSO guard missing'}
if($login -match 'flock'){Pass 'concurrent SSO sign-in attempts are serialised'}else{Fail 'SSO sign-in lock missing'}
if($dockerfile -match '/opt/snyk-cache' -and $secretRunner -match '/opt/snyk-cache'){Pass 'Snyk native runtime cache pre-warmed and seeded into the exec tmpfs'}else{Fail 'Snyk runtime cache pre-warm/seed missing'}
if($pocCompose -match 'SANDBOX_AWS_HOME' -and $ecrCompose -match 'SANDBOX_AWS_HOME'){Pass 'AWS state anchor exported by both Compose files'}else{Fail 'SANDBOX_AWS_HOME missing from Compose'}
$ssmPs1=Get-Content (Join-Path $Root 'scripts\platform\01-setup-ssm.ps1') -Raw
$ssmSh=Get-Content (Join-Path $Root 'scripts\platform\01-setup-ssm.sh') -Raw
if($ssmPs1 -match 'claude-api-key' -and $ssmPs1 -match 'gemini-api-key' -and $ssmSh -match 'claude-api-key' -and $ssmSh -match 'gemini-api-key' -and $secretRunner -match 'claude-api-key' -and $secretRunner -match 'gemini-api-key'){Pass 'direct Claude/Gemini API keys are SSM-managed'}else{Fail 'direct AI SSM parameter contract missing'}
if($secretRunner -match 'DATABRICKS_CLAUDE_MODEL is required' -and $secretRunner -match '--model "\$DATABRICKS_CLAUDE_MODEL"' -and $pocCompose -match 'DATABRICKS_CLAUDE_MODEL' -and $ecrCompose -match 'DATABRICKS_CLAUDE_MODEL'){Pass 'Claude model is explicit for ucode/Databricks'}else{Fail 'Databricks Claude model routing contract missing'}
if($secretRunner -match 'export GEMINI_MODEL="\$DATABRICKS_GEMINI_MODEL"' -and $pocCompose -match 'DATABRICKS_GEMINI_MODEL' -and $ecrCompose -match 'DATABRICKS_GEMINI_MODEL' -and $secretRunner -match 'export GEMINI_MODEL=""'){Pass 'Gemini model is explicit for ucode/Databricks while bare Gemini stays direct'}else{Fail 'Databricks Gemini model routing contract missing'}
$whitelist=Get-Content (Join-Path $Root 'squid\whitelist.txt')
if($whitelist -contains 'api.anthropic.com' -and $whitelist -contains 'generativelanguage.googleapis.com'){Pass 'direct Anthropic and Gemini API egress is allowlisted'}else{Fail 'direct AI provider egress missing'}
if($dockerfile -match 'stash_real ucode' -and $dockerfile -match '/usr/local/bin/ucode'){Pass 'ucode is stashed and wrapped as the explicit Databricks launcher'}else{Fail 'ucode wrapper installation missing'}

if($secretRunner -match 'run_logged_ephemeral_home tavily' -and $secretRunner -match 'run_logged_snyk_exec_home snyk' -and $secretRunner -match 'XDG_CACHE_HOME'){Pass 'Tavily and Snyk use ephemeral writable runtime state'}else{Fail 'Tavily/Snyk read-only HOME regression protection missing'}
if($secretRunner -match 'DATABRICKS_CLAUDE_MODEL is required' -and $secretRunner -match 'DATABRICKS_GEMINI_MODEL is required'){Pass 'ucode Claude/Gemini fail closed when approved Databricks target is missing'}else{Fail 'ucode Databricks target validation missing'}
if($secretRunner -match '--use-pat' -and $secretRunner -match 'mktemp -d /tmp/ai-sandbox-ucode' -and $secretRunner -match '--skip-validate'){Pass 'ucode uses temporary headless PAT configuration'}else{Fail 'ucode headless PAT routing contract missing'}
$verifySandboxPs1=Get-Content (Join-Path $Root 'scripts\poc\verify-sandbox.ps1') -Raw
if($verifySandboxPs1 -match 'function Dc\(\[string\[\]\]\$DockerArgs\)' -and $verifySandboxPs1 -notmatch 'function Dc\(\[string\[\]\]\$Args\)'){Pass 'PowerShell Docker Compose helper avoids automatic `$Args collision'}else{Fail 'verify-sandbox.ps1 still uses automatic `$Args parameter'}
$Obsolete=@('.devcontainer\.dockerignore','scripts\ecr\devcontainer.template.json','policies\registry.json.template','WINDOWS-QUICKSTART.md','RUNTIME-POLICY.md')
foreach($f in $Obsolete){if(Test-Path(Join-Path $Root $f)){Fail "obsolete duplicate returned: $f"}else{Pass "obsolete absent: $f"}}
$PsFiles = @(Get-ChildItem $Root -Recurse -Filter '*.ps1' -File)
foreach ($PsFile in $PsFiles) {
    $Head = (Get-Content $PsFile.FullName -TotalCount 12) -join "`n"
    if ($Head -match '(?im)^#Requires\s+-Version\s+7\.4(?:\s|$)') { Pass "PowerShell 7.4 requirement: $($PsFile.Name)" }
    else { Fail "PowerShell 7.4 requirement missing: $($PsFile.FullName)" }
}
# Parse every PowerShell file using the local parser.
Get-ChildItem $Root -Recurse -Filter '*.ps1' -File|ForEach-Object{$tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count){Fail "PowerShell syntax: $($_.FullName)"}else{Pass "PowerShell syntax: $($_.Name)"}}
Write-Host '======================================'
if($script:Failures){Write-Host "LINT FAILED: $script:Failures issue(s)." -ForegroundColor Red;exit 1};Write-Host 'LINT PASSED: package is structurally valid.' -ForegroundColor Green

$envTemplate=Get-Content (Join-Path $root 'templates/developer/env.example') -Raw
$runner=Get-Content (Join-Path $root '.devcontainer/scripts/run-with-ssm-secrets.sh') -Raw
$claudeHook=Get-Content (Join-Path $root '.devcontainer/scripts/claude-audit-hook.sh') -Raw
if($envTemplate -match 'SANDBOX_CONTENT_LOGGING=false'){Pass 'Content logging defaults to false'}else{Fail 'Content logging default missing'}
$dockerfile = Get-Content -Raw (Join-Path $Root '.devcontainer\Dockerfile')
$pocCompose = Get-Content -Raw (Join-Path $Root 'poc\docker-compose.yml')
$ecrCompose = Get-Content -Raw (Join-Path $Root 'ecr\docker-compose.yml')
$adminBuild = Get-Content -Raw (Join-Path $Root 'scripts\admin\build-sandbox.ps1')
$toolResolver = Get-Content -Raw (Join-Path $Root 'scripts\supply-chain\resolve-tool-artifacts.ps1')
if($dockerfile -match "ucode configure --help > /tmp/ucode-configure-help.txt 2>&1" -and $dockerfile -match "grep -Fq -- '--use-pat' /tmp/ucode-configure-help.txt" -and $adminBuild -match 'resolve-tool-artifacts.ps1 -Write -UcodeOnly' -and $toolResolver -match '\[switch\]\$UcodeOnly'){Pass 'ucode headless PAT capability is refreshed and build-time validated'}else{Fail 'ucode refresh/build-time validation missing'}
if($pocCompose -match '/run/ai-sandbox-snyk:rw,exec,nosuid,nodev' -and $ecrCompose -match '/run/ai-sandbox-snyk:rw,exec,nosuid,nodev' -and $secretRunner -match 'run_logged_snyk_exec_home'){Pass 'Snyk uses isolated executable tmpfs while /tmp remains noexec'}else{Fail 'Snyk executable tmpfs contract missing'}
if($claudeHook -match 'ucode-claude-content.log' -and $runner -match 'ucode-gemini-content.log'){Pass 'Databricks-routed content logs separated'}else{Fail 'Databricks content log routing missing'}
