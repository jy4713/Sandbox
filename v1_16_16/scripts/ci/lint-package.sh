#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Static regression checks for the v1.16.16 two-container / host-logging package.
# =============================================================================
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; failures=0
pass(){ echo "  [OK]   $*"; }; fail(){ echo "  [FAIL] $*" >&2; failures=$((failures+1)); }; skip(){ echo "  [SKIP] $*"; }
echo '=== AI Sandbox v1.16.16 package lint ==='

echo '[1/10] Bash syntax'
while IFS= read -r f; do bash -n "$f" >/dev/null 2>&1 && pass "${f#$root/}" || fail "${f#$root/}"; done < <(find "$root" -type f -name '*.sh' | sort)

echo '[2/10] PowerShell syntax'
if command -v pwsh >/dev/null 2>&1; then while IFS= read -r f; do pwsh -NoProfile -Command '$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$t,[ref]$e)|Out-Null;if($e.Count){$e|%{Write-Error $_};exit 1}' "$f" >/dev/null 2>&1 && pass "${f#$root/}" || fail "${f#$root/}"; done < <(find "$root" -type f -name '*.ps1' | sort); else skip 'pwsh unavailable'; fi
while IFS= read -r f; do if head -n 12 "$f" | grep -Eq '^#Requires[[:space:]]+-Version[[:space:]]+7\.4([[:space:]]|$)'; then pass "PowerShell 7.4 contract: ${f#$root/}"; else fail "PowerShell 7.4 requirement missing: ${f#$root/}"; fi; done < <(find "$root" -type f -name '*.ps1' | sort)

echo '[3/10] JSON / YAML parse'
while IFS= read -r f; do if [[ "$(basename "$f")" == devcontainer*.json ]]; then python3 - "$f" <<'PY' >/dev/null 2>&1
import json,re,sys
s=open(sys.argv[1],encoding='utf-8-sig').read();s=re.sub(r'^\s*//.*$','',s,flags=re.M);json.loads(s)
PY
else python3 -c 'import json,sys;json.load(open(sys.argv[1],encoding="utf-8-sig"))' "$f" >/dev/null 2>&1; fi; [[ $? -eq 0 ]] && pass "${f#$root/}" || fail "${f#$root/}"; done < <(find "$root" -type f -name '*.json' | sort)
if python3 -c 'import yaml' >/dev/null 2>&1; then while IFS= read -r f; do python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1],encoding="utf-8-sig"))' "$f" >/dev/null 2>&1 && pass "${f#$root/}" || fail "${f#$root/}"; done < <(find "$root" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort); else skip 'PyYAML unavailable'; fi

echo '[4/10] Required files'
required=(
  .build.env.example .env.example
  .devcontainer/Dockerfile .devcontainer/devcontainer.json .devcontainer/post-create.sh
  .devcontainer/scripts/run-with-ssm-secrets.sh .devcontainer/scripts/sandbox-command-wrapper.sh
  .devcontainer/scripts/sandbox-audit-logger.sh .devcontainer/scripts/application-audit.sh
  .devcontainer/scripts/claude-audit-hook.sh .devcontainer/scripts/configure-aws-sso.sh
  .devcontainer/scripts/sandbox-aws-login.sh .devcontainer/scripts/sandbox-info.sh
  scripts/admin/build-sandbox.ps1 scripts/admin/build-sandbox.sh
  scripts/admin/export-developer-packages.ps1 scripts/admin/export-developer-packages.sh
  scripts/applications/add-application.ps1 scripts/applications/add-application.sh
  scripts/applications/remove-application.ps1 scripts/applications/remove-application.sh
  scripts/applications/validate-application.ps1 scripts/applications/validate-application.sh
  scripts/applications/application-helper.py
  scripts/poc/build-and-export.ps1 scripts/poc/build-and-export.sh
  scripts/poc/load-and-start.ps1 scripts/poc/load-and-start.sh
  scripts/poc/verify-sandbox.ps1 scripts/poc/verify-sandbox.sh
  scripts/platform/02-setup-ecr.ps1 scripts/platform/02-setup-ecr.sh
  scripts/platform/03-setup-logging.ps1 scripts/platform/03-setup-logging.sh
  scripts/ecr/pull-and-start.ps1 scripts/ecr/pull-and-start.sh
  scripts/ecr/deploy-ecr.ps1 scripts/ecr/deploy-ecr.sh
  scripts/monitoring/send-logs-ingestion.ps1 scripts/monitoring/send-logs-ingestion.sh
  scripts/monitoring/verify-host-log-export.ps1 scripts/monitoring/verify-host-log-export.sh
  poc/docker-compose.yml ecr/docker-compose.yml squid/Dockerfile squid/whitelist.txt
  templates/developer/env.example templates/developer/devcontainer-production.json
  templates/developer/DEVELOPER-GUIDE-POC.md templates/developer/DEVELOPER-GUIDE-PRODUCTION.md
  sentinel/dcr-ama-custom-text.example.json sentinel/dcr-logs-ingestion.example.json sentinel/detection-rules.kql
)
for f in "${required[@]}"; do [[ -f "$root/$f" ]] && pass "$f" || fail "$f missing"; done

echo '[5/10] Fluent Bit removal regression guard'
[[ ! -d "$root/fluent-bit" ]] && pass 'fluent-bit directory absent' || fail 'fluent-bit directory still exists'
code_refs="$(grep -RInE 'sandbox-fluent-bit|FLUENT_BIT_BASE_IMAGE|AZURE_LAW_|azure-law-(workspace-id|shared-key)' "$root/scripts" "$root/poc" "$root/ecr" "$root/.build.env.example" "$root/.env.example" 2>/dev/null | grep -v 'lint-package' || true)"
[[ -z "$code_refs" ]] && pass 'no active Fluent Bit / Log Analytics shared-key references' || { echo "$code_refs" >&2; fail 'active Fluent Bit/shared-key references remain'; }

echo '[6/10] Two-image release contract'
grep -q 'sandbox-devcontainer.tar' "$root/scripts/poc/build-and-export.sh" && grep -q 'sandbox-squid.tar' "$root/scripts/poc/build-and-export.sh" && pass 'POC builds DevContainer + Squid' || fail 'POC image contract incomplete'
if grep -q 'sandbox-fluent-bit.tar' "$root/scripts/poc/build-and-export.sh"; then fail 'POC still exports Fluent Bit TAR'; else pass 'POC has no third monitoring TAR'; fi
grep -q "ai-sandbox/devcontainer" "$root/scripts/platform/02-setup-ecr.sh" && grep -q "ai-sandbox/squid" "$root/scripts/platform/02-setup-ecr.sh" && pass 'ECR builds DevContainer + Squid' || fail 'ECR image contract incomplete'

echo '[7/10] Host logging contract'
grep -q 'SANDBOX_LOG_ROOT' "$root/poc/docker-compose.yml" && grep -q 'SANDBOX_LOG_ROOT' "$root/ecr/docker-compose.yml" && pass 'Compose exports logs to host root' || fail 'host log bind mounts missing'
grep -q '/var/log/sandbox' "$root/poc/docker-compose.yml" && grep -q '/var/log/squid' "$root/poc/docker-compose.yml" && pass 'POC maps DevContainer and Squid logs' || fail 'POC log targets missing'
grep -Fq '"workspaceFolder": "/home/vscode/workspace"' "$root/.devcontainer/devcontainer.json" \
  && grep -Fq '"workspaceFolder": "/home/vscode/workspace"' "$root/templates/developer/devcontainer-production.json" \
  && grep -Fq 'target: /home/vscode/workspace' "$root/poc/docker-compose.yml" \
  && grep -Fq 'target: /home/vscode/workspace' "$root/ecr/docker-compose.yml" \
  && grep -Fq 'WORKDIR /home/${USERNAME}/workspace' "$root/.devcontainer/Dockerfile" \
  && pass 'Developer workspace is mounted under /home/vscode/workspace' || fail 'home-workspace contract missing'
if grep -RInE '(workspaceFolder"[[:space:]]*:[[:space:]]*"/workspace"|target:[[:space:]]*/workspace([[:space:]]|$)|WORKDIR[[:space:]]+/workspace([[:space:]]|$))' "$root/.devcontainer" "$root/poc" "$root/ecr" "$root/templates/developer" --exclude='lint-package.*' >/dev/null 2>&1; then fail 'legacy root-level /workspace runtime path remains'; else pass 'legacy root-level /workspace runtime path absent'; fi
grep -q 'SANDBOX_CONTENT_LOGGING: "${SANDBOX_CONTENT_LOGGING:-false}"' "$root/poc/docker-compose.yml" && grep -q 'GEMINI_TELEMETRY_LOG_PROMPTS: "false"' "$root/poc/docker-compose.yml" && pass 'POC content logging defaults off and Gemini prompts are disabled by default' || fail 'POC content-logging default policy missing'
grep -q '/usr/local/bin/claude-audit-hook' "$root/.devcontainer/Dockerfile" && grep -q '/etc/claude-code/managed-settings.json' "$root/.devcontainer/Dockerfile" && pass 'Claude managed audit hook is baked into image' || fail 'Claude managed audit hook missing'
grep -q '/usr/local/bin/application-audit' "$root/.devcontainer/Dockerfile" && pass 'application-audit helper is baked into image' || fail 'application-audit helper missing'
grep -q '/usr/local/libexec/ai-sandbox/sandbox-command-wrapper' "$root/.devcontainer/Dockerfile" && pass 'Developer-friendly SSM command wrapper is baked into image' || fail 'SSM command wrapper missing'
grep -q '/usr/local/bin/tavily-mcp-ssm' "$root/.devcontainer/scripts/configure-mcp.sh" && grep -q 'REAL_CLAUDE' "$root/.devcontainer/scripts/configure-mcp.sh" && grep -q 'REAL_GEMINI' "$root/.devcontainer/scripts/configure-mcp.sh" && pass 'Tavily MCP uses secret-free registration through real AI CLIs' || fail 'Tavily MCP registration path is incorrect'

grep -q '/usr/local/bin/databricks-sql-mcp-ssm' "$root/.devcontainer/scripts/configure-mcp.sh" \
  && grep -q 'databricks-sql-mcp-token' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && grep -q 'mcp-remote@${MCP_REMOTE_VERSION}' "$root/.devcontainer/Dockerfile" \
  && pass 'Databricks SQL MCP uses dedicated SSM token and pinned bridge' || fail 'Databricks SQL MCP contract missing'
grep -q 'tavily-policy-proxy.py' "$root/.devcontainer/scripts/tavily-mcp-ssm.sh" \
  && grep -q 'unset DEFAULT_PARAMETERS' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && grep -q 'tavily-allowed-domains.json' "$root/.devcontainer/Dockerfile" \
  && pass 'Tavily MCP domain allowlist is enforced by Admin-owned proxy' || fail 'Tavily hard domain policy missing'
grep -q '"WebSearch"' "$root/.devcontainer/Dockerfile" \
  && grep -q 'google_web_search' "$root/.devcontainer/policies/gemini-web-policy.toml" \
  && pass 'Claude/Gemini native web tools are disabled by Admin policy' || fail 'Admin native-web deny policy missing'


# v1.16.16 - Gemini MCP requires explicit runtime AWS references because the
# Gemini CLI strips inherited sensitive variables from stdio MCP children.
! grep -Eq "mcp add .*-e ['\"]?[A-Z_]+=\\\$" "$root/.devcontainer/scripts/configure-mcp.sh" && pass 'Gemini MCP does not use CLI -e credential injection' || fail 'Gemini MCP still uses command-line env injection'
grep -Fq 'AWS_ACCESS_KEY_ID: "$AWS_ACCESS_KEY_ID"' "$root/.devcontainer/scripts/configure-mcp.sh" \
  && grep -Fq 'AWS_SECRET_ACCESS_KEY: "$AWS_SECRET_ACCESS_KEY"' "$root/.devcontainer/scripts/configure-mcp.sh" \
  && grep -Fq 'AWS_SESSION_TOKEN: "$AWS_SESSION_TOKEN"' "$root/.devcontainer/scripts/configure-mcp.sh" \
  && grep -Fq 'managed Gemini MCP env must contain only approved AWS runtime references' "$root/.devcontainer/scripts/configure-mcp.sh" \
  && pass 'Gemini MCP stores only approved runtime AWS references, never values' || fail 'Gemini MCP runtime-reference contract missing'
grep -Fq 'gemini_state_home="${GEMINI_CLI_HOME:-$HOME}"' "$root/.devcontainer/scripts/configure-mcp.sh" \
  && grep -Fq 'GEMINI_CLI_HOME="$ucode_gemini_cli_home"' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && grep -Fq 'from ucode.agents.gemini import GEMINI_HOME_DIR' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && pass 'direct and ucode Gemini MCP settings target the correct Gemini state homes' || fail 'ucode Gemini GEMINI_CLI_HOME MCP contract missing'
grep -q 'mcpServers' "$root/.devcontainer/scripts/configure-mcp.sh" && grep -q 'AWS access-key credential material detected' "$root/.devcontainer/scripts/configure-mcp.sh" && pass 'MCP settings are written deterministically with a credential-value self-check' || fail 'MCP settings writer or credential self-check missing'
helper="$root/scripts/applications/application-helper.py"
grep -Fq 'mcp-wrapper-preamble' "$helper" \
  && grep -Fq 'AWS_ACCESS_KEY_ID: "$AWS_ACCESS_KEY_ID"' "$helper" \
  && grep -Fq '"$gemini_config_dir"' "$helper" \
  && ! grep -Fq '"$REAL_GEMINI" mcp add' "$helper" \
  && pass 'Admin application helper preserves the v1.16.16 Gemini MCP contract' || fail 'application helper would regress Gemini MCP registration'
grep -q 'SANDBOX_AWS_HOME' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -q 'HOME="\$AWS_STATE_HOME" aws' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'AWS CLI state is pinned to a HOME-independent anchor for SSO reachability' || fail 'AWS state anchor missing; SSO breaks under ephemeral HOME'
grep -q 'SANDBOX_NONINTERACTIVE' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -q 'SANDBOX_NONINTERACTIVE' "$root/.devcontainer/scripts/sandbox-aws-login.sh" && pass 'interactive SSO sign-in is refused in MCP stdio contexts' || fail 'non-interactive SSO guard missing'
for w in tavily-mcp-ssm databricks-sql-mcp-ssm snyk-mcp-ssm; do
  grep -q 'mcp-wrapper-preamble' "$root/.devcontainer/scripts/$w.sh" || fail "$w does not source the MCP wrapper preamble"
done
pass 'MCP wrappers source the deterministic environment preamble'
grep -q '/opt/snyk-cache' "$root/.devcontainer/Dockerfile" && grep -q '/opt/snyk-cache' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'Snyk native runtime cache is pre-warmed and seeded into the exec tmpfs' || fail 'Snyk runtime cache pre-warm/seed missing'
grep -Fq -- '--reuse-hardened-base' "$root/scripts/admin/build-sandbox.sh" \
  && grep -Fq 'can_reuse_hardened_base' "$root/scripts/admin/build-sandbox.sh" \
  && grep -Fq 'hardening.method' "$root/scripts/admin/build-sandbox.sh" \
  && grep -Fq 'hardening.profile' "$root/scripts/admin/build-sandbox.sh" \
  && grep -Fq 'Falling back automatically to a new hardened-base build' "$root/scripts/admin/build-sandbox.sh" \
  && grep -Fq -- '-ReuseHardenedBase' "$root/scripts/admin/build-sandbox.ps1" \
  && grep -Fq 'Test-ReusableHardenedBase' "$root/scripts/admin/build-sandbox.ps1" \
  && pass 'validated hardened-base reuse with automatic full-build fallback' || fail 'hardened-base reuse/fallback contract missing'
grep -Fq -- '--build-env-source' "$root/scripts/admin/build-sandbox.sh" \
  && grep -Fq -- '-BuildEnvSource' "$root/scripts/admin/build-sandbox.ps1" \
  && grep -Fq "v1.16.16" "$root/.build.env.example" \
  && pass 'previous .build.env migration and v1.16.16 stamping supported' || fail 'build-env reuse migration/version stamping missing'
grep -Fq 'exec "$SECRET_RUNNER" --profile anthropic -- "$(real_tool claude)"' "$root/.devcontainer/scripts/sandbox-command-wrapper.sh" \
  && grep -Fq 'exec "$SECRET_RUNNER" --profile gemini -- "$(real_tool gemini)"' "$root/.devcontainer/scripts/sandbox-command-wrapper.sh" \
  && grep -Fq 'exec "$SECRET_RUNNER" --profile databricks -- "$(real_tool ucode)"' "$root/.devcontainer/scripts/sandbox-command-wrapper.sh" \
  && grep -Fq 'exec "$SECRET_RUNNER" --profile databricks -- "$(real_tool databricks)"' "$root/.devcontainer/scripts/sandbox-command-wrapper.sh" \
  && pass 'direct Claude/Gemini and explicit ucode/Databricks routing are separated' || fail 'AI command routing contract missing'
grep -q 'AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID:-}"' "$root/poc/docker-compose.yml" && grep -q 'AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY:-}"' "$root/ecr/docker-compose.yml" && grep -q 'AWS_SSO_START_URL: "${AWS_SSO_START_URL:-}"' "$root/poc/docker-compose.yml" && grep -q 'SANDBOX_AWS_PROFILE:' "$root/poc/docker-compose.yml" && ! grep -Eq '^[[:space:]]+AWS_PROFILE:' "$root/poc/docker-compose.yml" && ! grep -Eq '^[[:space:]]+AWS_PROFILE:' "$root/ecr/docker-compose.yml" && pass 'AWS dual-mode values mapped without AWS_PROFILE injection' || fail 'AWS dual-mode Compose/profile isolation missing'
grep -q 'aws_auth_mode="static"' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -q 'drop_aws_bootstrap_credentials' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -q 'Tavily/Snyk MCP wrappers' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'static AWS credentials have first priority with leaf-process stripping and AI/MCP inheritance' || fail 'static AWS key-first runtime flow with MCP inheritance missing'
grep -q 'Non-secret compatibility profile for static environment credentials' "$root/.devcontainer/scripts/configure-aws-sso.sh" \
  && grep -q '\[default\]' "$root/.devcontainer/scripts/configure-aws-sso.sh" \
  && grep -q 'SANDBOX_AWS_PROFILE' "$root/.devcontainer/scripts/configure-aws-sso.sh" \
  && grep -q 'configure-aws-sso >/dev/null' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && pass 'AWS_PROFILE is isolated while default/named AWS config is prepared' || fail 'AWS profile isolation/bootstrap missing'
grep -q 'sandbox-aws-login' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -q -- '--use-device-code --no-browser' "$root/.devcontainer/scripts/sandbox-aws-login.sh" && pass 'SSO remains the browser fallback when static keys are absent' || fail 'automatic SSO fallback flow missing'
grep -Fq 'claude-api-key' "$root/scripts/platform/01-setup-ssm.sh" && grep -Fq 'gemini-api-key' "$root/scripts/platform/01-setup-ssm.ps1" && grep -Fq 'claude-api-key' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -Fq 'gemini-api-key' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'direct Claude/Gemini API keys are SSM-managed' || fail 'direct AI SSM parameter contract missing'
grep -Fq 'DATABRICKS_CLAUDE_MODEL is required' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && grep -Fq -- '--model "$DATABRICKS_CLAUDE_MODEL"' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && grep -Fq 'DATABRICKS_CLAUDE_MODEL: "${DATABRICKS_CLAUDE_MODEL:-}"' "$root/poc/docker-compose.yml" \
  && grep -Fq 'DATABRICKS_CLAUDE_MODEL: "${DATABRICKS_CLAUDE_MODEL:-}"' "$root/ecr/docker-compose.yml" \
  && pass 'Claude model is explicit for ucode/Databricks' \
  || fail 'Databricks Claude model routing contract missing'
grep -Fq 'export GEMINI_MODEL="$DATABRICKS_GEMINI_MODEL"' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && grep -Fq 'DATABRICKS_GEMINI_MODEL: "${DATABRICKS_GEMINI_MODEL:-}"' "$root/poc/docker-compose.yml" \
  && grep -Fq 'DATABRICKS_GEMINI_MODEL: "${DATABRICKS_GEMINI_MODEL:-}"' "$root/ecr/docker-compose.yml" \
  && grep -Fq 'export GEMINI_MODEL=""' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && pass 'Gemini model is explicit for ucode/Databricks while bare Gemini stays direct' || fail 'Databricks Gemini model routing contract missing'
grep -Fxq 'api.anthropic.com' "$root/squid/whitelist.txt" && grep -Fxq 'generativelanguage.googleapis.com' "$root/squid/whitelist.txt" && pass 'direct Anthropic and Gemini API egress is allowlisted' || fail 'direct AI provider egress missing'
grep -Fq 'stash_real ucode' "$root/.devcontainer/Dockerfile" && grep -Fq '/usr/local/bin/ucode' "$root/.devcontainer/Dockerfile" && pass 'ucode is stashed and wrapped as the explicit Databricks launcher' || fail 'ucode wrapper installation missing'
grep -Fq 'run_logged_ephemeral_home tavily' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && grep -Fq 'run_logged_snyk_exec_home snyk' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && grep -Fq 'XDG_CACHE_HOME="$tmp_home/.cache"' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" \
  && pass 'Tavily and Snyk use ephemeral writable runtime state' || fail 'Tavily/Snyk read-only HOME regression protection missing'
grep -Fq 'DATABRICKS_CLAUDE_MODEL is required' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -Fq 'DATABRICKS_GEMINI_MODEL is required' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'ucode Claude/Gemini fail closed when approved Databricks target is missing' || fail 'ucode Databricks target validation missing'
grep -Fq -- '--use-pat' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -Fq 'mktemp -d /tmp/ai-sandbox-ucode' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && grep -Fq -- '--skip-validate' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'ucode uses temporary headless PAT configuration' || fail 'ucode headless PAT routing contract missing'
grep -Fq 'function Dc([string[]]$DockerArgs){ & docker compose -f $Compose @DockerArgs }' "$root/scripts/poc/verify-sandbox.ps1" \
  && ! grep -Fq 'function Dc([string[]]$Args)' "$root/scripts/poc/verify-sandbox.ps1" \
  && pass 'PowerShell Docker Compose helper avoids automatic $Args variable collision' || fail 'verify-sandbox.ps1 still uses reserved/automatic $Args parameter'
grep -Fq "ucode configure --help > /tmp/ucode-configure-help.txt 2>&1" "$root/.devcontainer/Dockerfile" && grep -Fq "grep -Fq -- '--use-pat' /tmp/ucode-configure-help.txt" "$root/.devcontainer/Dockerfile" && grep -Fq -- '--ucode-only' "$root/scripts/supply-chain/resolve-tool-artifacts.sh" && grep -Fq 'resolve-tool-artifacts.ps1 -Write -UcodeOnly' "$root/scripts/admin/build-sandbox.ps1" && pass 'ucode headless PAT capability is refreshed and build-time validated' || fail 'ucode refresh/build-time validation missing'
grep -Fq '/run/ai-sandbox-snyk:rw,exec,nosuid,nodev' "$root/poc/docker-compose.yml" && grep -Fq '/run/ai-sandbox-snyk:rw,exec,nosuid,nodev' "$root/ecr/docker-compose.yml" && grep -Fq 'run_logged_snyk_exec_home' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'Snyk uses isolated executable tmpfs while /tmp remains noexec' || fail 'Snyk executable tmpfs contract missing'
grep -Fq 'vim-tiny' "$root/.devcontainer/Dockerfile" && grep -Fq "'set nomodeline'" "$root/.devcontainer/Dockerfile" && grep -Fq "'set noexrc'" "$root/.devcontainer/Dockerfile" && grep -Fq "'set noswapfile'" "$root/.devcontainer/Dockerfile" && grep -Fq 'chmod 0444 /etc/vim/vimrc.local' "$root/.devcontainer/Dockerfile" && pass 'minimal vi is installed with hardened immutable configuration' || fail 'secure vi/vim-tiny configuration missing'
grep -q '/etc/ai-sandbox/build-info.json' "$root/.devcontainer/Dockerfile" && grep -q '/usr/local/bin/sandbox-info' "$root/.devcontainer/Dockerfile" && pass 'Developer build/runtime info is available without Admin source' || fail 'sandbox-info/build-info missing'
grep -q 'SANDBOX_AUDIT_REQUIRED: "${SANDBOX_AUDIT_REQUIRED:-true}"' "$root/poc/docker-compose.yml" && grep -q 'SANDBOX_AUDIT_REQUIRED: "${SANDBOX_AUDIT_REQUIRED:-true}"' "$root/ecr/docker-compose.yml" && pass 'application audit required by default' || fail 'application audit policy missing'
if command -v jq >/dev/null 2>&1; then
  hook_tmp="$(mktemp)"
  sensitive="DO-NOT-LOG-$RANDOM-$$"
  printf '%s' "{\"session_id\":\"lint-session\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$sensitive\"}" \
    | CLAUDE_AUDIT_LOG="$hook_tmp" DEVELOPER_ID=lint "$root/.devcontainer/scripts/claude-audit-hook.sh"
  if grep -Fq "$sensitive" "$hook_tmp"; then fail 'Claude audit hook copied prompt content'; else pass 'Claude audit hook redacts prompt content'; fi
  grep -Fq '"prompt_length"' "$hook_tmp" && pass 'Claude hook records prompt length only' || fail 'Claude hook prompt-length metadata missing'
  content_tmp="$(mktemp)"
  printf '%s' "{\"session_id\":\"lint-session\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$sensitive\"}" \
    | SANDBOX_CONTENT_LOGGING=true SANDBOX_AI_ROUTE=direct-anthropic CLAUDE_AUDIT_LOG="$hook_tmp" CLAUDE_CONTENT_LOG="$content_tmp" "$root/.devcontainer/scripts/claude-audit-hook.sh" >/dev/null 2>&1 || true
  if grep -Fq "$sensitive" "$content_tmp" 2>/dev/null; then pass 'Claude content logging is opt-in'; else fail 'Claude opt-in content log missing prompt'; fi
  rm -f "$hook_tmp" "$content_tmp"
else
  skip 'jq unavailable for Claude redaction regression test'
fi

if command -v jq >/dev/null 2>&1; then
  audit_tmp="$(mktemp -d)"
  SANDBOX_AUDIT_DIR="$audit_tmp" DEVELOPER_ID=lint SANDBOX_ENV=poc "$root/.devcontainer/scripts/application-audit.sh" \
    --app tavily --event process_start --operation 'DO NOT LOG THIS QUERY' --target tavily --status started
  if grep -Fq 'DO NOT LOG THIS QUERY' "$audit_tmp/tavily-events.log"; then fail 'application audit copied free-form content'; else pass 'application audit rejects/redacts free-form metadata'; fi
  grep -Fq '"operation":"redacted"' "$audit_tmp/tavily-events.log" && pass 'application audit emitted redacted marker' || fail 'application audit redaction marker missing'
  rm -rf "$audit_tmp"
else
  skip 'jq unavailable for application audit regression test'
fi

echo '[8/10] Unsafe runtime / secret patterns'
for spec in 'privileged:[[:space:]]*true' '/var/run/docker\.sock:' 'image:[[:space:]]+[^#[:space:]]*:latest'; do if grep -RInE "$spec" "$root" --exclude='lint-package.*' --exclude='*.md' >/dev/null 2>&1; then fail "unsafe pattern: $spec"; else pass "no unsafe pattern: $spec"; fi; done
if grep -RInE '(dapi[a-zA-Z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' "$root" --exclude='lint-package.*' >/dev/null 2>&1; then fail 'potential secret material found'; else pass 'no obvious committed secret material'; fi

echo '[9/10] SH/PS1 workflow parity'
while IFS= read -r sh; do ps="${sh%.sh}.ps1"; [[ "$sh" == "$root/scripts/common/load-build-env.sh" ]] && ps="$root/scripts/common/Load-BuildEnv.ps1"; [[ -f "$ps" ]] && pass "${sh#$root/}" || fail "missing PS1 peer for ${sh#$root/}"; done < <(find "$root/scripts" "$root/ado-scripts" -type f -name '*.sh' | sort)
while IFS= read -r ps; do sh="${ps%.ps1}.sh"; [[ "$ps" == "$root/scripts/common/Load-BuildEnv.ps1" ]] && sh="$root/scripts/common/load-build-env.sh"; [[ -f "$sh" ]] || fail "missing SH peer for ${ps#$root/}"; done < <(find "$root/scripts" "$root/ado-scripts" -type f -name '*.ps1' | sort)

obsolete=(.devcontainer/.dockerignore scripts/ecr/devcontainer.template.json policies/registry.json.template WINDOWS-QUICKSTART.md RUNTIME-POLICY.md)
for f in "${obsolete[@]}"; do [[ ! -e "$root/$f" ]] && pass "obsolete absent: $f" || fail "obsolete duplicate returned: $f"; done

echo '[10/10] Squid whitelist overlap'
mapfile -t wl < <(grep -vE '^\s*(#|$)' "$root/squid/whitelist.txt" | tr '[:upper:]' '[:lower:]'); overlap=0
for child in "${wl[@]}"; do for parent in "${wl[@]}"; do [[ "$parent" == .* ]] || continue; [[ "$child" == "$parent" ]] && continue; bare="${parent#.}"; if [[ "$child" == "$bare" || "$child" == *"$parent" ]]; then fail "whitelist overlap: $child covered by $parent"; overlap=1; fi; done; done
((overlap==0)) && pass 'no overlapping Squid domains'

echo '======================================'
if ((failures)); then echo "LINT FAILED: $failures issue(s)." >&2; exit 1; fi
echo 'LINT PASSED: package is structurally valid.'

# v1.16.16 optional content logging contract
grep -Fq 'SANDBOX_CONTENT_LOGGING=false' "$root/templates/developer/env.example" && pass 'content logging defaults to false' || fail 'content logging default missing'
grep -Fq 'ucode-claude-content.log' "$root/.devcontainer/scripts/claude-audit-hook.sh" && grep -Fq 'ucode-gemini-content.log' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'Databricks-routed agent content logs are separated' || fail 'ucode content log routing missing'
grep -Fq 'GEMINI_TELEMETRY_TRACES_ENABLED="true"' "$root/.devcontainer/scripts/run-with-ssm-secrets.sh" && pass 'Gemini response/content traces are gated by runtime wrapper' || fail 'Gemini content trace toggle missing'
