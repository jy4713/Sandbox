#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Safely parses and validates .build.env for Linux Admin workflows without sourcing it as executable code.
# Admin maintenance: When a new build-time application requires a version/hash variable, add it to validation/default handling here and in Load-BuildEnv.ps1.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# load-build-env.sh  —  shared .build.env loader (sourced by admin scripts)
#
# Purpose:
#   Safely loads KEY=VALUE build parameters from .build.env (or
#   $BUILD_ENV_FILE) into the environment of the CALLING script. It never
#   evals or sources the file as code: every line is parsed as literal
#   text, keys must match [A-Za-z_][A-Za-z0-9_]*, and values are assigned
#   with printf -v. This keeps a tampered .build.env from becoming arbitrary
#   code execution in an admin build context.
#
# Validation performed (fail-closed, non-zero exit / return 1):
#   - All required keys present and not left as REPLACE_* placeholders
#     (BASE_IMAGE, NODE_IMAGE, SQUID_BASE_IMAGE,
#     CLAUDE_CODE_VERSION, GEMINI_CLI_VERSION, AWSCLI_URL/SHA256,
#     DATABRICKS_CLI_VERSION/URL/SHA256, UCODE_GIT_REF, SSG_VERSION/URL/
#     SHA256, CIS_PROFILE_ID)
#   - *_SHA256 values are exactly 64 hex chars; UCODE_GIT_REF is 40 hex
#   - All three image references are digest-pinned (repo@sha256:...)
#   Also supplies defaults: DEVCONTAINER_TARGET=baseline,
#   SANDBOX_VERSION=v1.16.16, NPM_REGISTRY, GCM_VERSION, REQUIRE_CIS_PASS.
#
# Usage (from another script):
#   source "$(dirname "$0")/../common/load-build-env.sh"
# Setup when it reports missing values:
#   cp .build.env.example .build.env
#   bash scripts/supply-chain/resolve-base-digests.sh --write
#   bash scripts/supply-chain/resolve-tool-artifacts.sh --write
#
# Windows equivalent: scripts/common/Load-BuildEnv.ps1 (returns a hashtable)
# =============================================================================
set -euo pipefail
_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_env_file="${BUILD_ENV_FILE:-$_root/.build.env}"

if [[ ! -f "$_env_file" ]]; then
    echo "ERROR: $_env_file not found." >&2
    echo "  cp .build.env.example .build.env" >&2
    echo "  bash scripts/supply-chain/resolve-base-digests.sh --write" >&2
    echo "  bash scripts/supply-chain/resolve-tool-artifacts.sh --write" >&2
    return 1 2>/dev/null || exit 1
fi

while IFS= read -r _line || [[ -n "$_line" ]]; do
    _line="${_line%$'\r'}"
    [[ -z "${_line//[[:space:]]/}" || "$_line" =~ ^[[:space:]]*# ]] && continue
    [[ "$_line" == *=* ]] || { echo "ERROR: invalid line in $_env_file: $_line" >&2; return 1 2>/dev/null || exit 1; }
    _key="${_line%%=*}"; _val="${_line#*=}"
    _key="${_key//[[:space:]]/}"
    [[ "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "ERROR: invalid key in .build.env: $_key" >&2; return 1 2>/dev/null || exit 1; }
    printf -v "$_key" '%s' "$_val"
    export "$_key"
done < "$_env_file"

_required=(
  BASE_IMAGE NODE_IMAGE SQUID_BASE_IMAGE
  CLAUDE_CODE_VERSION GEMINI_CLI_VERSION TAVILY_CLI_VERSION TAVILY_MCP_VERSION MCP_REMOTE_VERSION SNYK_CLI_VERSION
  AWSCLI_URL AWSCLI_SHA256
  DATABRICKS_CLI_VERSION DATABRICKS_CLI_URL DATABRICKS_CLI_SHA256 UCODE_GIT_REF
  SSG_VERSION SSG_URL SSG_SHA256 CIS_PROFILE_ID
)
_missing=()
for _var in "${_required[@]}"; do
    _val="${!_var:-}"
    if [[ -z "$_val" || "$_val" == *REPLACE_* ]]; then _missing+=("$_var"); fi
done
if (( ${#_missing[@]} > 0 )); then
    echo "ERROR: Missing/unresolved values in $_env_file:" >&2
    printf '  - %s\n' "${_missing[@]}" >&2
    echo "Run both supply-chain resolver scripts with --write." >&2
    return 1 2>/dev/null || exit 1
fi

for _var in AWSCLI_SHA256 DATABRICKS_CLI_SHA256 SSG_SHA256; do
    [[ "${!_var}" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "ERROR: $_var must be 64 hex characters" >&2; return 1 2>/dev/null || exit 1; }
done
[[ "$UCODE_GIT_REF" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "ERROR: UCODE_GIT_REF must be a 40-hex commit" >&2; return 1 2>/dev/null || exit 1; }
for _var in BASE_IMAGE NODE_IMAGE SQUID_BASE_IMAGE; do
    [[ "${!_var}" == *@sha256:* ]] || { echo "ERROR: $_var must be digest-pinned: ${!_var}" >&2; return 1 2>/dev/null || exit 1; }
done

: "${DEVCONTAINER_TARGET:=baseline}"
: "${SANDBOX_VERSION:=v1.16.16}"
: "${RELEASE_TAG:=$SANDBOX_VERSION}"
: "${NPM_REGISTRY:=https://registry.npmjs.org}"
: "${GCM_VERSION:=2.5.0}"
: "${GCM_SHA256:=}"
: "${REQUIRE_CIS_PASS:=false}"
export DEVCONTAINER_TARGET SANDBOX_VERSION RELEASE_TAG NPM_REGISTRY GCM_VERSION GCM_SHA256 REQUIRE_CIS_PASS

echo "[build-env] Loaded: $_env_file"
echo "[build-env]   BASE_IMAGE = $BASE_IMAGE"
echo "[build-env]   NODE_IMAGE = $NODE_IMAGE"
echo "[build-env]   TARGET     = $DEVCONTAINER_TARGET"
echo "[build-env]   RELEASE    = $RELEASE_TAG"
