#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Prepare host-visible Sandbox log folders for host-side forwarding.
# Usage: 03-setup-logging.sh [AMA|LogsIngestionApi|None] [log-root]
# =============================================================================
set -euo pipefail
MODE="${1:-None}"
LOG_ROOT="${2:-/var/log/ai-sandbox}"
mkdir -p "$LOG_ROOT/devcontainer" "$LOG_ROOT/squid"
echo "[OK] Host log root: $LOG_ROOT"
echo "Set SANDBOX_LOG_ROOT=$LOG_ROOT in the runtime .env"
case "$MODE" in
  AMA)
    echo 'Configure the platform-supported Azure Monitor Agent/DCR collection path.'
    echo 'See sentinel/README.md and the DCR example files under sentinel/.'
    ;;
  LogsIngestionApi)
    echo 'Use scripts/monitoring/send-logs-ingestion.sh or the enterprise host sender.'
    echo 'See sentinel/README.md and the DCR example files under sentinel/.'
    ;;
  None)
    echo 'No forwarding method selected. Logs remain on the host.'
    ;;
  *)
    echo 'ERROR: use AMA, LogsIngestionApi or None' >&2
    exit 2
    ;;
esac
