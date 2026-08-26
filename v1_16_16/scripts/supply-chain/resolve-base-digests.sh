#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Resolves immutable digests for external base images and optionally writes them into .build.env.
# Admin maintenance: Add another base image here only if a new Docker build stage depends on a separately maintained upstream image.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# resolve-base-digests.sh — Resolve current digests for all base images
#
# Usage:
#   bash scripts/supply-chain/resolve-base-digests.sh           # print only
#   bash scripts/supply-chain/resolve-base-digests.sh --write   # update .build.env
#
# Requires: docker buildx, internet access
# =============================================================================
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
write_mode="${1:-}"

command -v docker >/dev/null 2>&1 \
    || { echo "ERROR: docker not found in PATH" >&2; exit 1; }

docker buildx version >/dev/null 2>&1 \
    || { echo "ERROR: docker buildx not available" >&2; exit 1; }

resolve() {
    local ref="$1"
    local digest
    digest=$(docker buildx imagetools inspect "$ref" \
        --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"') || return 1
    [[ -n "$digest" ]] || return 1
    printf '%s' "$digest"
}

ubuntu_ref="${UBUNTU_REF:-ubuntu:24.04}"
node_ref="${NODE_REF:-node:20-bookworm-slim}"

echo "Resolving image digests..." >&2

for pair in "ubuntu:$ubuntu_ref" "node:$node_ref"; do
    name="${pair%%:*}"
    ref="${pair#*:}"
    echo "  $name -> $ref" >&2
done

ubuntu_digest="$(resolve "$ubuntu_ref")" \
    || { echo "ERROR: cannot resolve $ubuntu_ref (check network / docker login)" >&2; exit 1; }
node_digest="$(resolve "$node_ref")" \
    || { echo "ERROR: cannot resolve $node_ref" >&2; exit 1; }

out="BASE_IMAGE=${ubuntu_ref}@${ubuntu_digest}
SQUID_BASE_IMAGE=${ubuntu_ref}@${ubuntu_digest}
NODE_IMAGE=${node_ref}@${node_digest}"

if [[ "$write_mode" == "--write" ]]; then
    env_file="$root/.build.env"
    if [[ ! -f "$env_file" ]]; then
        echo "ERROR: $env_file not found." >&2
        echo "  Fix: cp .build.env.example .build.env" >&2
        exit 1
    fi
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        python3 - "$env_file" "$key" "$value" <<'PY'
import sys, re
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding='utf-8').read()
pattern = rf'^{re.escape(key)}=.*$'
if re.search(pattern, text, flags=re.M):
    text = re.sub(pattern, f'{key}={value}', text, flags=re.M)
else:
    text += f'\n{key}={value}\n'
open(path, 'w', encoding='utf-8').write(text)
PY
        echo "  [written] $key" >&2
    done <<< "$out"
    echo "Digests written to $env_file" >&2
else
    printf '%s\n' "$out"
    echo >&2
    echo "To write these into .build.env:  bash $0 --write" >&2
fi
