#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Host-side POC validation of container state, egress policy, read-only controls and expected components.
# Admin maintenance: Add/remove application checks when a new tool must be proven present or a new outbound service must be proven allowed/blocked.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# verify-sandbox.sh  —  DEVELOPER/ADMIN side, post-start security verification
#
# Purpose:
#   Runs on the host (Windows 365 VM, Git Bash) AFTER the stack is up
#   (scripts/poc/load-and-start.sh, or the ECR equivalent) and proves that
#   the sandbox actually enforces its security model. Exits non-zero if any
#   FAIL check triggers, so it can gate onboarding or CI.
#
# Test groups:
#   1. Stack / proxy health      - Squid container healthy
#   2. Host internet (informational only)
#   3. Whitelisted egress        - github.com, registry.npmjs.org,
#                                  dev.azure.com, login.microsoftonline.com
#                                  and the Databricks workspace MUST be
#                                  reachable THROUGH the Squid proxy
#   4. Non-whitelisted egress    - api.anthropic.com, example.com,
#                                  google.com MUST be blocked (403/407/000)
#   5. True proxy bypass         - direct (no-proxy) HTTP and raw TCP to
#                                  1.1.1.1:443 MUST fail (internal network)
#   6. DNS-over-HTTPS            - dns.google / cloudflare-dns / quad9 MUST
#                                  be blocked (prevents whitelist bypass
#                                  via alternate DNS)
#   7. CONNECT port restriction  - CONNECT github.com:22 MUST be blocked
#   8. Container hardening       - non-root user (vscode), no sudo binary,
#                                  NET_ADMIN blocked, verify-runtime passes
#   9. Audit / logging           - /var/log/sandbox/audit.log exists and
#                                  host-exported log files are available
#
# Usage:
#   bash scripts/poc/verify-sandbox.sh [poc|ecr]
#     poc (default) - verify the POC compose stack (poc/docker-compose.yml)
#     ecr           - verify the Production compose stack (ecr/docker-compose.yml)
#   Note: this argument selects the COMPOSE FILE, not the hardening mode;
#   the hardening mode (poc/production) was fixed at image build time.
#
# Windows equivalent: scripts/poc/verify-sandbox.ps1 (same checks)
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SVC_DIR="${1:-poc}"
COMPOSE="$ROOT/$SVC_DIR/docker-compose.yml"
PASS=0; FAIL=0; WARN=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn(){ echo "  [WARN] $1"; WARN=$((WARN+1)); }
cd "$ROOT"
DC=(docker compose -f "$COMPOSE")

proxy_code(){
  "${DC[@]}" exec -T devcontainer sh -c 'curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -x http://squid-proxy:3128 "$1" 2>/dev/null || printf 000' sh "$1" 2>/dev/null | tail -c 3
}
direct_code(){
  "${DC[@]}" exec -T devcontainer sh -c 'env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy curl --noproxy "*" -sS -o /dev/null -w "%{http_code}" --max-time 5 "$1" 2>/dev/null || printf 000' sh "$1" 2>/dev/null | tail -c 3
}

echo "================================================"
echo "  AI Sandbox Security Verification ($SVC_DIR)"
echo "================================================"

echo; echo "--- Stack / proxy health ---"
if "${DC[@]}" ps squid-proxy 2>/dev/null | grep -qiE 'healthy|running|up'; then ok 'Squid proxy is running/healthy'; else fail 'Squid proxy is not healthy'; fi

echo; echo "--- Host machine (informational) ---"
host_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 https://example.com 2>/dev/null || printf 000)"
[[ "$host_code" =~ ^[23][0-9]{2}$ ]] && ok "Host -> example.com ($host_code)" || warn "Host internet check ($host_code)"

echo; echo "--- Whitelisted egress (must reach destination) ---"
for url in https://github.com https://registry.npmjs.org https://dev.azure.com https://login.microsoftonline.com https://api.tavily.com https://api.snyk.io; do
  c="$(proxy_code "$url")"
  [[ "$c" =~ ^[23][0-9]{2}$ ]] && ok "Container -> $url ($c)" || fail "Container -> $url did not return 2xx/3xx ($c)"
done
# Databricks workspace is a mandatory allowlisted route; 2xx/3xx is expected for the workspace root.
db_code="$("${DC[@]}" exec -T devcontainer sh -c 'curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -x http://squid-proxy:3128 "${DATABRICKS_HOST%/}" 2>/dev/null || printf 000' 2>/dev/null | tail -c 3)"
[[ "$db_code" =~ ^[23][0-9]{2}$ ]] && ok "Container -> Databricks workspace ($db_code)" || fail "Databricks workspace not reachable through Squid ($db_code)"

echo; echo "--- Non-whitelisted vendor/public egress (must be blocked) ---"
for url in http://api.anthropic.com http://example.com http://google.com; do
  c="$(proxy_code "$url")"
  [[ "$c" == 403 || "$c" == 407 || "$c" == 000 ]] && ok "Container -> $url BLOCKED ($c)" || fail "Container -> $url reachable ($c)"
done

echo; echo "--- True proxy-bypass/direct egress (must be blocked) ---"
for url in http://93.184.216.34 http://1.1.1.1; do
  c="$(direct_code "$url")"
  [[ "$c" == 000 ]] && ok "Direct/no-proxy -> $url BLOCKED" || fail "Direct/no-proxy -> $url reachable ($c)"
done
if "${DC[@]}" exec -T devcontainer bash -c 'env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy timeout 4 bash -c "</dev/tcp/1.1.1.1/443"' >/dev/null 2>&1; then
  fail 'Direct TCP -> 1.1.1.1:443 reachable (proxy bypass exists)'
else
  ok 'Direct TCP -> 1.1.1.1:443 blocked'
fi

echo; echo "--- DNS over HTTPS via proxy (must be blocked) ---"
for doh in https://dns.google/resolve?name=example.com https://cloudflare-dns.com/dns-query https://dns.quad9.net/dns-query; do
  c="$(proxy_code "$doh")"; host="${doh#https://}"; host="${host%%/*}"
  [[ "$c" == 403 || "$c" == 407 || "$c" == 000 ]] && ok "DoH -> $host BLOCKED ($c)" || fail "DoH -> $host reachable ($c)"
done

echo; echo "--- CONNECT port restriction ---"
r="$(proxy_code https://github.com:22)"
[[ "$r" == 403 || "$r" == 407 || "$r" == 000 ]] && ok "CONNECT github.com:22 BLOCKED ($r)" || fail "CONNECT github.com:22 unexpectedly reachable ($r)"

echo; echo "--- Container hardening ---"
u="$("${DC[@]}" exec -T devcontainer whoami 2>/dev/null || true)"
[[ "$u" == vscode ]] && ok 'Non-root user: vscode' || fail "Running as: ${u:-unknown}"
if "${DC[@]}" exec -T devcontainer sh -c 'command -v sudo >/dev/null 2>&1' >/dev/null 2>&1; then fail 'sudo binary is installed'; else ok 'sudo binary is absent'; fi
if "${DC[@]}" exec -T devcontainer sh -c 'command -v iptables >/dev/null 2>&1' >/dev/null 2>&1; then
  out="$("${DC[@]}" exec -T devcontainer iptables -L 2>&1 || true)"
  echo "$out" | grep -qiE 'Operation not permitted|Permission denied' && ok 'NET_ADMIN blocked' || warn 'iptables exists; verify NET_ADMIN/capabilities'
else ok 'iptables not installed'; fi
if "${DC[@]}" exec -T devcontainer bash -lc verify-runtime >/dev/null 2>&1; then ok 'verify-runtime passed'; else fail 'verify-runtime failed'; fi

echo; echo "--- Audit / host logging ---"
if "${DC[@]}" exec -T devcontainer test -f /var/log/sandbox/audit.log 2>/dev/null; then ok 'audit.log exists inside devcontainer'; else fail 'audit.log missing inside devcontainer'; fi
LOG_ROOT="$(sed -n 's/^SANDBOX_LOG_ROOT=//p' "$ROOT/.env" 2>/dev/null | tail -n1 | tr -d '\r')"; [[ -n "$LOG_ROOT" ]] || LOG_ROOT="$ROOT/logs"; [[ "$LOG_ROOT" = /* ]] || LOG_ROOT="$ROOT/$LOG_ROOT"
[[ -f "$LOG_ROOT/devcontainer/audit.log" ]] && ok "host-visible audit log: $LOG_ROOT/devcontainer/audit.log" || warn "host-visible audit log not found yet: $LOG_ROOT/devcontainer/audit.log"
[[ -d "$LOG_ROOT/squid" ]] && ok "host-visible Squid log directory: $LOG_ROOT/squid" || warn "host-visible Squid log directory not found: $LOG_ROOT/squid"
echo '================================================'
echo "  Result: $PASS passed  $FAIL failed  $WARN warnings"
echo '================================================'
(( FAIL == 0 )) || exit 1
