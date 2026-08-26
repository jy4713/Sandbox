#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose:
#   One-time/Admin provisioning of a Production Developer runtime on Linux.
#   This script does not build or push ECR images.
#
# Logging:
#   Prepares a host log root. AMA-equivalent/central collection or the host-side
#   Logs Ingestion API sender is configured separately by the platform team.
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:-/opt/ai-sandbox}"
LOG_ROOT="${SANDBOX_LOG_ROOT:-/var/log/ai-sandbox}"

install -d -m 0755 \
  "$TARGET" \
  "$TARGET/.devcontainer" \
  "$TARGET/scripts/ecr" \
  "$TARGET/monitoring"
install -d -m 0775 "$TARGET/workspace" "$LOG_ROOT/devcontainer" "$LOG_ROOT/squid"

install -m 0444 "$ROOT/ecr/docker-compose.yml" "$TARGET/docker-compose.yml"
install -m 0444 "$ROOT/templates/developer/devcontainer-production.json" "$TARGET/.devcontainer/devcontainer.json"
install -m 0555 "$ROOT/scripts/ecr/pull-and-start.sh" "$TARGET/scripts/ecr/pull-and-start.sh"
install -m 0444 "$ROOT/scripts/ecr/pull-and-start.ps1" "$TARGET/scripts/ecr/pull-and-start.ps1"
install -m 0555 "$ROOT/scripts/monitoring/verify-host-log-export.sh" "$TARGET/monitoring/verify-host-log-export.sh"
install -m 0555 "$ROOT/scripts/monitoring/send-logs-ingestion.sh" "$TARGET/monitoring/send-logs-ingestion.sh"

sed "s|^SANDBOX_LOG_ROOT=.*|SANDBOX_LOG_ROOT=$LOG_ROOT|" \
  "$ROOT/templates/developer/env.example" > "$TARGET/.env.example"
chmod 0444 "$TARGET/.env.example"

echo "[OK] Runtime provisioned at $TARGET"
echo "[OK] Host logs: $LOG_ROOT"
echo "[INFO] Configure host-side log forwarding separately."
