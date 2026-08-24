#!/usr/bin/env bash
# =============================================================================
# AI Secure Sandbox - INTERIM HOTFIX for v1.16.13 containers
#
# Scope:   Repairs the Gemini MCP registration in the CURRENT container without
#          rebuilding the image. Run INSIDE the DevContainer as vscode.
#
# Fixes:   - removes AWS credentials / '$VAR' placeholders from MCP settings
#          - raises the MCP start-up timeout so SSM resolution can complete
#          - reports whether AWS authentication is usable by MCP servers
#
# Does NOT fix (image rebuild to v1.16.14 required):
#          - `ucode claude` / `ucode gemini` MCP, which regenerate the broken
#            registration inside their own temporary HOME on every launch
#          - IAM Identity Center reachability from those temporary HOMEs
#          - interactive-signin / audit-failure aborts inside MCP stdio
#          - Snyk native-runtime cache pre-warming
#
# Safety:  Modifies only $HOME/.gemini/settings.json. Takes a backup first.
#          Prints no secret value.
# =============================================================================
set -euo pipefail
umask 077

settings="${HOME}/.gemini/settings.json"
ts="$(date -u +%Y%m%dT%H%M%SZ)"

echo '=== AI Sandbox MCP hotfix (v1.16.13 interim) ==='

if [[ ! -f "$settings" ]]; then
  echo "ERROR: $settings not found. Open a DevContainer session first." >&2
  exit 1
fi

cp -a "$settings" "${settings}.bak-${ts}"
chmod 0600 "${settings}.bak-${ts}"
echo "[1/4] Backup written: ${settings}.bak-${ts}"

# --- detect what is currently wrong -----------------------------------------
leaked=0
if grep -Eq '(AKIA|ASIA)[A-Z0-9]{16}' "$settings"; then leaked=1; fi
placeholder=0
if grep -q '\$AWS_' "$settings"; then placeholder=1; fi

# --- rewrite the two managed servers ----------------------------------------
python3 - "$settings" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)

servers = data.get("mcpServers") or {}
# Whole-value replacement, not a merge: any existing env block is discarded.
servers["tavily"] = {
    "command": "/usr/local/bin/tavily-mcp-ssm",
    "args": [],
    "timeout": 120000,
}
servers["snyk"] = {
    "command": "/usr/local/bin/snyk-mcp-ssm",
    "args": [],
    "timeout": 180000,
}
data["mcpServers"] = servers

with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
chmod 0600 "$settings"
echo '[2/4] Gemini MCP registration rewritten (secret-free, timeouts raised)'

# --- verify ------------------------------------------------------------------
fail=0
grep -Eq '(AKIA|ASIA)[A-Z0-9]{16}|aws_secret_access_key' "$settings" && { echo '  [FAIL] credential material still present'; fail=1; } || echo '  [OK]   no AWS credential material'
grep -q '\$AWS_' "$settings" && { echo '  [FAIL] unexpanded placeholders still present'; fail=1; } || echo '  [OK]   no unexpanded placeholders'
python3 - "$settings" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("mcpServers", {})
ok = True
for name, min_to in (("tavily", 60000), ("snyk", 120000)):
    e = s.get(name, {})
    if "env" in e:
        print(f'  [FAIL] {name} still carries an env block'); ok = False
    if e.get("timeout", 0) < min_to:
        print(f'  [FAIL] {name} timeout too low'); ok = False
if ok:
    print('  [OK]   both managed servers are env-free with adequate timeouts')
PY
echo '[3/4] Verification complete'

# --- AWS authentication readiness -------------------------------------------
echo '[4/4] AWS authentication readiness for MCP servers'
if [[ -n "${AWS_ACCESS_KEY_ID:-}" && "${AWS_ACCESS_KEY_ID:0:1}" != '$' ]]; then
  echo '  Mode: static key pair (inherited by MCP servers automatically)'
  if env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE aws sts get-caller-identity \
        --region "${AWS_REGION:-eu-west-2}" >/dev/null 2>&1; then
    echo '  [OK]   STS identity valid'
  else
    echo '  [FAIL] STS validation failed - correct the static keys in .env'
    fail=1
  fi
else
  echo '  Mode: IAM Identity Center SSO'
  if aws sts get-caller-identity --profile "${SANDBOX_AWS_PROFILE:-sandbox}" \
        --region "${AWS_REGION:-eu-west-2}" >/dev/null 2>&1; then
    echo '  [OK]   SSO session valid; MCP servers can fetch their SSM secrets'
  else
    echo '  [ACTION] No active SSO session. Run `sandbox-aws-login` in this'
    echo '           terminal BEFORE using Tavily/Snyk MCP tools. An MCP stdio'
    echo '           server cannot display a device code itself.'
  fi
fi

cat <<'MSG'

--- Reminders -------------------------------------------------------------
1. If an AKIA/ASIA key was present in this file, it was exposed on disk.
   Erasing it is NOT rotation. Deactivate and delete that IAM access key,
   issue a replacement, and review CloudTrail for its use.
2. This fix is overwritten the next time post-create runs configure-mcp from
   the old v1.16.13 image. Re-run this script, or upgrade to v1.16.14.
3. `ucode claude` / `ucode gemini` MCP is NOT repaired by this script.
   It requires the v1.16.14 image.
---------------------------------------------------------------------------
MSG

exit "$fail"
