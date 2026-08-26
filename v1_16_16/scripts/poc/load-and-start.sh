#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose:
#   Developer POC launcher for the approved DevContainer + Squid TAR bundle.
#
# Maintenance boundary:
#   Keep the required bundle files, runtime-policy verification, image ID
#   checks, and the paired PowerShell launcher synchronized with
#   scripts/poc/build-and-export.*.
#
# Logging:
#   Creates host-visible DevContainer and Squid log directories. No monitoring
#   or Sentinel-forwarding container is started.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGES="$ROOT/poc/images"
ENV_FILE="$ROOT/.env"
COMPOSE="$ROOT/poc/docker-compose.yml"

required=(
  sandbox-devcontainer.tar
  sandbox-squid.tar
  image-manifest.json
  image-manifest.env
  runtime-policy.sha256
  SHA256SUMS
)
for file in "${required[@]}"; do
  [[ -s "$IMAGES/$file" ]] || {
    echo "ERROR: missing/empty $IMAGES/$file" >&2
    exit 1
  }
done

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT/.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE. Configure runtime values and rerun. Protect .env if AWS static credentials are used." >&2
  exit 2
fi

get_env() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r'
}

DEVELOPER_ID="$(get_env DEVELOPER_ID)"
[[ -n "$DEVELOPER_ID" && "$DEVELOPER_ID" != yourname ]] || {
  echo 'ERROR: DEVELOPER_ID is missing or still a placeholder' >&2
  exit 1
}

configured_value() {
  local v="${1:-}"
  [[ -n "$v" && "$v" != *'<'* && "$v" != *'>'* && "$v" != *REPLACE_* && "$v" != yourname ]]
}
ACCESS_KEY="$(get_env AWS_ACCESS_KEY_ID)"
SECRET_KEY="$(get_env AWS_SECRET_ACCESS_KEY)"
SESSION_TOKEN="$(get_env AWS_SESSION_TOKEN)"
if [[ -n "$ACCESS_KEY" || -n "$SECRET_KEY" || -n "$SESSION_TOKEN" ]]; then
  [[ -n "$ACCESS_KEY" && -n "$SECRET_KEY" ]] || { echo 'ERROR: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be configured together; partial static credentials do not fall back to SSO.' >&2; exit 1; }
  export AWS_ACCESS_KEY_ID="$ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
  if [[ -n "$SESSION_TOKEN" ]]; then export AWS_SESSION_TOKEN="$SESSION_TOKEN"; else unset AWS_SESSION_TOKEN; fi
  echo 'AWS authentication mode: static environment credentials (SSO values are not required).'
else
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  for key in SANDBOX_AWS_PROFILE AWS_REGION AWS_SSO_SESSION AWS_SSO_START_URL AWS_SSO_REGION AWS_SSO_ACCOUNT_ID AWS_SSO_ROLE_NAME; do
    value="$(get_env "$key")"
    configured_value "$value" || {
      echo "ERROR: $key is missing or still a placeholder in .env. No static AWS key pair is configured, so IAM Identity Center values are required." >&2
      exit 1
    }
  done
  [[ "$(get_env AWS_SSO_START_URL)" == https://* ]] || { echo 'ERROR: AWS_SSO_START_URL must use https://' >&2; exit 1; }
  [[ "$(get_env AWS_SSO_ACCOUNT_ID)" =~ ^[0-9]{12}$ ]] || { echo 'ERROR: AWS_SSO_ACCOUNT_ID must be a 12-digit AWS account ID' >&2; exit 1; }
  echo 'AWS authentication mode: IAM Identity Center (SSO) fallback.'
fi

# Resolve host logging. On native Linux use an absolute POSIX path. On Windows
# PowerShell use the paired .ps1 launcher. Git Bash paths are accepted when
# cygpath is available.
LOG_ROOT="$(get_env SANDBOX_LOG_ROOT)"
if [[ -z "$LOG_ROOT" ]]; then
  LOG_ROOT="$ROOT/logs"
elif [[ "$LOG_ROOT" =~ ^[A-Za-z]:[/\\] ]] && command -v cygpath >/dev/null 2>&1; then
  LOG_ROOT="$(cygpath -u "$LOG_ROOT")"
elif [[ "$LOG_ROOT" != /* ]]; then
  LOG_ROOT="$ROOT/$LOG_ROOT"
fi
mkdir -p "$LOG_ROOT/devcontainer" "$LOG_ROOT/squid"
LOG_ROOT="$(cd "$LOG_ROOT" && pwd)"
export SANDBOX_LOG_ROOT="$LOG_ROOT"
echo "Host log root: $LOG_ROOT"

echo '[1/5] Verifying bundle hashes...'
(
  cd "$IMAGES"
  sha256sum -c SHA256SUMS
)

echo '[2/5] Verifying Admin runtime policy...'
while read -r hash rel; do
  [[ -n "$hash" ]] || continue
  rel="${rel#\*}"
  case "$rel" in
    .devcontainer/devcontainer.json|poc/docker-compose.yml) ;;
    *)
      echo "ERROR: unexpected runtime-policy path: $rel" >&2
      exit 1
      ;;
  esac
  actual="$(sha256sum "$ROOT/$rel" | awk '{print $1}')"
  [[ "$actual" == "$hash" ]] || {
    echo "ERROR: runtime policy mismatch: $rel" >&2
    exit 1
  }
done < "$IMAGES/runtime-policy.sha256"

echo '[3/5] Loading approved images...'
docker load -i "$IMAGES/sandbox-devcontainer.tar" >/dev/null
docker load -i "$IMAGES/sandbox-squid.tar" >/dev/null

declare -A manifest=()
while IFS='=' read -r key value; do
  case "$key" in
    DEVCONTAINER_TAG|DEVCONTAINER_ID|SQUID_TAG|SQUID_ID)
      manifest[$key]="${value%$'\r'}"
      ;;
  esac
done < "$IMAGES/image-manifest.env"

for key in DEVCONTAINER_TAG DEVCONTAINER_ID SQUID_TAG SQUID_ID; do
  [[ -n "${manifest[$key]:-}" ]] || {
    echo "ERROR: image manifest missing $key" >&2
    exit 1
  }
done

verify_image() {
  local label="$1" tag="$2" expected="$3" actual
  actual="$(docker image inspect "$tag" --format '{{.Id}}')"
  [[ "$actual" == "$expected" ]] || {
    echo "ERROR: $label image ID mismatch" >&2
    exit 1
  }
  echo "  [OK] $label $actual"
}

echo '[4/5] Verifying loaded image IDs...'
verify_image devcontainer "${manifest[DEVCONTAINER_TAG]}" "${manifest[DEVCONTAINER_ID]}"
verify_image squid "${manifest[SQUID_TAG]}" "${manifest[SQUID_ID]}"

echo '[5/5] Starting sandbox...'
docker compose --env-file "$ENV_FILE" -f "$COMPOSE" config >/dev/null
docker compose --env-file "$ENV_FILE" -f "$COMPOSE" up -d --force-recreate

echo '[OK] Sandbox started.'
echo "[OK] Host logs: $LOG_ROOT"
