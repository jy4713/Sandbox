#!/usr/bin/env bash
# =============================================================================
# ADMIN ONLY - Export minimal POC and Production Developer runtime packages.
# Documentation is optional and is not required by this export workflow.
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/developer-packages}"
INCLUDE="${2:-}"
POC="$OUT/AI_Sandbox_Developer_POC"
PROD="$OUT/AI_Sandbox_Developer_Production"
rm -rf "$POC" "$PROD"
mkdir -p "$POC" "$PROD"

copy(){ mkdir -p "$(dirname "$2")"; cp -a "$1" "$2"; }

# Stamp optional Admin-approved NON-SECRET SSO fallback defaults from .build.env into
# the Developer .env.example. Missing values are acceptable when the Developer supplies the static AWS key pair;
# otherwise the launchers require the SSO fallback values.
stamp_sso_defaults(){
  local target="$1" build="$ROOT/.build.env" key src value tmp
  [[ -f "$target" && -f "$build" ]] || return 0
  while IFS='|' read -r key src; do
    value="$(awk -F= -v k="$src" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$build")"
    [[ -n "$value" ]] || continue
    tmp="${target}.tmp.$$"
    awk -v k="$key" -v v="$value" 'index($0,k"=")==1 {$0=k"="v} {print}' "$target" > "$tmp"
    mv "$tmp" "$target"
  done <<'MAP'
SANDBOX_AWS_PROFILE|DEVELOPER_AWS_PROFILE
AWS_REGION|DEVELOPER_AWS_REGION
AWS_SSO_SESSION|DEVELOPER_AWS_SSO_SESSION
AWS_SSO_START_URL|DEVELOPER_AWS_SSO_START_URL
AWS_SSO_REGION|DEVELOPER_AWS_SSO_REGION
AWS_SSO_ACCOUNT_ID|DEVELOPER_AWS_SSO_ACCOUNT_ID
AWS_SSO_ROLE_NAME|DEVELOPER_AWS_SSO_ROLE_NAME
MAP
}

# POC package
copy "$ROOT/.devcontainer/devcontainer.json" "$POC/.devcontainer/devcontainer.json"
copy "$ROOT/poc/docker-compose.yml" "$POC/poc/docker-compose.yml"
for f in load-and-start.ps1 load-and-start.sh verify-sandbox.ps1 verify-sandbox.sh; do
  copy "$ROOT/scripts/poc/$f" "$POC/scripts/poc/$f"
done
copy "$ROOT/templates/developer/env.example" "$POC/.env.example"
stamp_sso_defaults "$POC/.env.example"
copy "$ROOT/workspace/README.md" "$POC/workspace/README.md"
copy "$ROOT/templates/developer/DEVELOPER-GUIDE-POC.md" "$POC/DEVELOPER-GUIDE.md"
mkdir -p "$POC/poc/images"
printf '%s\n' 'Admin supplies the complete generated poc/images bundle here. Do not modify bundle files.' > "$POC/poc/images/README.txt"
if [[ "$INCLUDE" == '--include-poc-images' ]]; then
  [[ -f "$ROOT/poc/images/SHA256SUMS" ]] || { echo 'ERROR: POC image bundle has not been built yet.' >&2; exit 1; }
  cp -a "$ROOT/poc/images/." "$POC/poc/images/"
fi

# Production package
copy "$ROOT/ecr/docker-compose.yml" "$PROD/docker-compose.yml"
copy "$ROOT/templates/developer/devcontainer-production.json" "$PROD/.devcontainer/devcontainer.json"
for f in pull-and-start.ps1 pull-and-start.sh; do
  copy "$ROOT/scripts/ecr/$f" "$PROD/scripts/ecr/$f"
done
copy "$ROOT/templates/developer/env.example" "$PROD/.env.example"
stamp_sso_defaults "$PROD/.env.example"
copy "$ROOT/workspace/README.md" "$PROD/workspace/README.md"
copy "$ROOT/templates/developer/DEVELOPER-GUIDE-PRODUCTION.md" "$PROD/DEVELOPER-GUIDE.md"

echo "[OK] $POC"
echo "[OK] $PROD"
