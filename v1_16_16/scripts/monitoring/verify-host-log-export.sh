#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Verify DevContainer -> host log export, Claude redaction, and the
#          structured application audit files used for Anthropic/Gemini/Databricks/Tavily/Snyk/
#          ADO/HiddenLayer/MCP attribution.
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE="${1:-$ROOT/poc/docker-compose.yml}"
LOG_ROOT="${2:-$ROOT/logs}"
MARK="host_log_test_$(date +%s)_$$"
CLAUDE_MARK="claude_hook_test_$(date +%s)_$$"

docker compose -f "$COMPOSE" exec -T devcontainer sh -c \
  'printf "%s | HOST_LOG_TEST | %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> /var/log/sandbox/audit.log' \
  sh "$MARK"

printf '%s' "{\"session_id\":\"$CLAUDE_MARK\",\"cwd\":\"/home/vscode/workspace\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"DO-NOT-LOG-$CLAUDE_MARK\"}" \
  | docker compose -f "$COMPOSE" exec -T devcontainer /usr/local/bin/claude-audit-hook

for app in anthropic gemini databricks tavily snyk ado git hiddenlayer mcp; do
  docker compose -f "$COMPOSE" exec -T devcontainer /usr/local/bin/application-audit \
    --app "$app" --event verification --operation host-export --target test --status success
 done

sleep 1
grep -Fq "$MARK" "$LOG_ROOT/devcontainer/audit.log"
grep -Fq "$CLAUDE_MARK" "$LOG_ROOT/devcontainer/claude-events.log"
if grep -Fq "DO-NOT-LOG-$CLAUDE_MARK" "$LOG_ROOT/devcontainer/claude-events.log"; then
  echo 'ERROR: Claude audit hook copied prompt content into the host log.' >&2
  exit 1
fi

for app in anthropic gemini databricks tavily snyk ado git hiddenlayer mcp; do
  file="$LOG_ROOT/devcontainer/${app}-events.log"
  [[ -f "$file" ]] || { echo "ERROR: application audit file not found: $file" >&2; exit 1; }
  grep -Fq '"event":"verification"' "$file" || { echo "ERROR: application audit marker not found: $file" >&2; exit 1; }
done

echo "[PASS] Host audit export verified: $LOG_ROOT/devcontainer/audit.log"
echo "[PASS] Claude redacted audit export verified: $LOG_ROOT/devcontainer/claude-events.log"
echo "[PASS] Application audit export verified for Anthropic, Gemini, Databricks, Tavily, Snyk, ADO, Git, HiddenLayer and MCP."
