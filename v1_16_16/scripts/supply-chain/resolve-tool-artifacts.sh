#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Resolves SHA-256 hashes/immutable commits for downloaded build artifacts and optionally writes .build.env.
# Admin maintenance: If a new application is downloaded outside a package manager, add its URL/hash resolution here and validate the hash in the Dockerfile.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# resolve-tool-artifacts.sh  —  ADMIN side, supply-chain pinning (step 2 of 2)
#
# Purpose:
#   Resolves the exact SHA-256 of every tool artifact downloaded at image
#   build time, and pins the Databricks ucode repository to the current
#   immutable commit of refs/heads/main. Together with
#   resolve-base-digests.sh (which pins the base IMAGE digests) this makes
#   every external input to the docker builds reproducible and auditable.
#
#   Artifacts resolved (URLs are read from .build.env):
#     AWSCLI_URL            -> AWSCLI_SHA256
#     DATABRICKS_CLI_URL    -> DATABRICKS_CLI_SHA256
#     SSG_URL               -> SSG_SHA256   (ComplianceAsCode data stream,
#                            also consumed by build-hardened-base.sh and
#                            assess-cis-l1.sh)
#     GCM_VERSION           -> GCM_SHA256   (Git Credential Manager .deb,
#                            URL derived from the version)
#     ucode git repo        -> UCODE_GIT_REF (40-hex commit of main)
#
#   Downloads are HTTPS-only (curl --proto '=https' --tlsv1.2). Without
#   --write the script only PRINTS the resolved values; with --write it
#   updates .build.env in place (preserving all other lines).
#
# Run order (admin, once per release / whenever a tool version changes):
#   1. cp .build.env.example .build.env   (fill versions + URLs)
#   2. bash scripts/supply-chain/resolve-base-digests.sh --write
#   3. bash scripts/supply-chain/resolve-tool-artifacts.sh --write   <-- this
#   4. bash scripts/hardening/build-hardened-base.sh --sandbox-type <poc|production>
#
# Usage:
#   bash scripts/supply-chain/resolve-tool-artifacts.sh [--write]
#
# Windows equivalent: scripts/supply-chain/resolve-tool-artifacts.ps1 (-Write)
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${BUILD_ENV_FILE:-$ROOT/.build.env}"
WRITE=false
UCODE_ONLY=false
while (($#)); do
  case "$1" in
    --write) WRITE=true ;;
    --ucode-only) UCODE_ONLY=true ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -f "$ENV_FILE" ]] || {
  echo "ERROR: $ENV_FILE not found. Copy .build.env.example to .build.env first." >&2
  exit 1
}

getv() { grep -m1 -E "^$1=" "$ENV_FILE" | cut -d= -f2-; }
setv() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    python3 - "$ENV_FILE" "$key" "$value" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); key=sys.argv[2]; val=sys.argv[3]
lines=p.read_text(encoding='utf-8-sig').splitlines()
out=[]
for line in lines:
    out.append(f'{key}={val}' if line.startswith(key+'=') else line)
p.write_text('\n'.join(out)+'\n',encoding='utf-8')
PY
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

hash_url() {
  local url="$1" label="$2" tmp
  [[ "$url" == https://* ]] || { echo "ERROR: $label URL must use https" >&2; return 1; }
  tmp="$(mktemp)"
  curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$tmp"
  local h; h="$(sha256sum "$tmp" | awk '{print $1}')"
  rm -f "$tmp"
  printf '%s' "$h"
}

AWSCLI_URL="$(getv AWSCLI_URL)"
DB_URL="$(getv DATABRICKS_CLI_URL)"
SSG_URL="$(getv SSG_URL)"
GCM_VERSION="$(getv GCM_VERSION)"

AWS_HASH=''
DB_HASH=''
SSG_HASH=''
if [[ "$UCODE_ONLY" != true ]]; then
  AWS_HASH="$(hash_url "$AWSCLI_URL" 'AWS CLI')"
  DB_HASH="$(hash_url "$DB_URL" 'Databricks CLI')"
  SSG_HASH="$(hash_url "$SSG_URL" 'ComplianceAsCode')"
fi
UCODE_REF="$(git ls-remote https://github.com/databricks/ucode.git refs/heads/main | awk 'NR==1 {print $1}')"
[[ "$UCODE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "ERROR: could not resolve ucode main commit" >&2; exit 1; }

GCM_HASH=""
if [[ "$UCODE_ONLY" != true && -n "$GCM_VERSION" ]]; then
  GCM_URL="https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux_amd64.${GCM_VERSION}.deb"
  GCM_HASH="$(hash_url "$GCM_URL" 'Git Credential Manager')"
fi

if [[ "$UCODE_ONLY" != true ]]; then
  printf 'AWSCLI_SHA256=%s\n' "$AWS_HASH"
  printf 'DATABRICKS_CLI_SHA256=%s\n' "$DB_HASH"
  printf 'SSG_SHA256=%s\n' "$SSG_HASH"
fi
printf 'UCODE_GIT_REF=%s\n' "$UCODE_REF"
[[ -n "$GCM_HASH" ]] && printf 'GCM_SHA256=%s\n' "$GCM_HASH"

if $WRITE; then
  if [[ "$UCODE_ONLY" != true ]]; then
    setv AWSCLI_SHA256 "$AWS_HASH"
    setv DATABRICKS_CLI_SHA256 "$DB_HASH"
    setv SSG_SHA256 "$SSG_HASH"
  fi
  setv UCODE_GIT_REF "$UCODE_REF"
  [[ -n "$GCM_HASH" ]] && setv GCM_SHA256 "$GCM_HASH"
  echo "[OK] Updated $ENV_FILE"
else
  echo "Re-run with --write to update $ENV_FILE"
fi
