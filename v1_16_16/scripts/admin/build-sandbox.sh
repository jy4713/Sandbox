#!/usr/bin/env bash
# =============================================================================
# ADMIN unified build entry point.
# v1.16.16 adds --skip-cis-assessment for POC-only fast iteration and preserves --reuse-hardened-base.
# Reuse is accepted only when .build.env is complete and the exact hardened
# digest is available and labelled for the requested hardening mode/profile.
# Otherwise the script automatically falls back to the full hardening path.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
PACKAGE_VERSION='v1.16.16'

usage(){
  cat >&2 <<'EOF'
Usage:
  build-sandbox.sh <SandboxType> [UbuntuProToken] [--reuse-hardened-base] [--skip-cis-assessment] [--build-env-source PATH]

Examples:
  bash scripts/admin/build-sandbox.sh POC --reuse-hardened-base --skip-cis-assessment
  bash scripts/admin/build-sandbox.sh POC --reuse-hardened-base --build-env-source ../v1.16.4/.build.env
  bash scripts/admin/build-sandbox.sh Production --reuse-hardened-base
  bash scripts/admin/build-sandbox.sh Production "$UBUNTU_PRO_TOKEN"
EOF
}

TYPE="${1:-}"
[[ -n "$TYPE" ]] || { usage; exit 2; }
shift

TOKEN="${UBUNTU_PRO_TOKEN:-}"
REUSE=false
SKIP_CIS=false
BUILD_ENV_SOURCE=''
while (($#)); do
  case "$1" in
    --reuse-hardened-base)
      REUSE=true; shift ;;
    --skip-cis-assessment)
      SKIP_CIS=true; shift ;;
    --build-env-source)
      [[ $# -ge 2 ]] || { echo 'ERROR: --build-env-source requires a path.' >&2; exit 2; }
      BUILD_ENV_SOURCE="$2"; shift 2 ;;
    --ubuntu-pro-token)
      [[ $# -ge 2 ]] || { echo 'ERROR: --ubuntu-pro-token requires a value.' >&2; exit 2; }
      TOKEN="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --*)
      echo "ERROR: unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$TOKEN" ]]; then TOKEN="$1"; shift; else echo "ERROR: unexpected argument: $1" >&2; usage; exit 2; fi ;;
  esac
done

BUILD_ENV="$ROOT/.build.env"
EXPECTED_MODE='production'
[[ "${TYPE,,}" == 'poc' ]] && EXPECTED_MODE='poc'

if [[ "$SKIP_CIS" == true && "$EXPECTED_MODE" != 'poc' ]]; then
  echo 'ERROR: --skip-cis-assessment is permitted only with SandboxType POC.' >&2
  exit 2
fi
[[ "$SKIP_CIS" == true ]] && echo 'WARNING: CIS/OpenSCAP assessment will be skipped. POC/test use only; not security-assessed release evidence.' >&2

set_env_value(){
  local key="$1" value="$2" tmp="${BUILD_ENV}.tmp.$$"
  awk -v k="$key" -v v="$value" '
    BEGIN{found=0}
    index($0,k"=")==1 {$0=k"="v; found=1}
    {print}
    END{if(!found) print k"="v}
  ' "$BUILD_ENV" > "$tmp"
  mv "$tmp" "$BUILD_ENV"
}

get_env_value(){
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$BUILD_ENV" 2>/dev/null || true
}

update_package_version(){
  [[ -f "$BUILD_ENV" ]] || return 0
  local old_version old_release
  old_version="$(get_env_value SANDBOX_VERSION)"
  old_release="$(get_env_value RELEASE_TAG)"
  set_env_value SANDBOX_VERSION "$PACKAGE_VERSION"
  if [[ -z "$old_release" || "$old_release" == "$old_version" || "$old_release" == 'v1.16.4' ]]; then
    set_env_value RELEASE_TAG "$PACKAGE_VERSION"
  fi
}

apply_hardened_env(){
  local src="$ROOT/hardened-base-build/hardened-base.env" line key
  [[ -f "$src" ]] || { echo "ERROR: hardened base environment file not found: $src" >&2; return 1; }
  local base='' squid=''
  while IFS= read -r line; do
    case "$line" in
      BASE_IMAGE=*) base="${line#*=}" ;;
      SQUID_BASE_IMAGE=*) squid="${line#*=}" ;;
    esac
  done < "$src"
  [[ -n "$base" && -n "$squid" ]] || { echo 'ERROR: hardened-base builder did not produce BASE_IMAGE and SQUID_BASE_IMAGE.' >&2; return 1; }
  set_env_value BASE_IMAGE "$base"
  set_env_value SQUID_BASE_IMAGE "$squid"
}

validate_build_env(){
  BUILD_ENV_FILE="$BUILD_ENV" bash -c 'source scripts/common/load-build-env.sh >/dev/null'
}

ensure_image_available(){
  local ref="$1"
  docker image inspect "$ref" >/dev/null 2>&1 && return 0
  echo "[reuse] Exact digest is not materialized locally; attempting docker pull: $ref"
  docker pull "$ref" >/dev/null 2>&1
}

can_reuse_hardened_base(){
  echo '[reuse] Checking whether the existing hardened base can be reused...'
  if ! validate_build_env; then
    echo '[reuse] .build.env is incomplete or invalid.' >&2
    return 1
  fi

  local base squid method profile
  base="$(get_env_value BASE_IMAGE)"
  squid="$(get_env_value SQUID_BASE_IMAGE)"
  if [[ "$base" != "$squid" ]]; then
    echo '[reuse] BASE_IMAGE and SQUID_BASE_IMAGE are not the same digest.' >&2
    return 1
  fi

  command -v docker >/dev/null 2>&1 || { echo '[reuse] docker is unavailable.' >&2; return 1; }
  if ! ensure_image_available "$base"; then
    echo "[reuse] Hardened base digest is unavailable: $base" >&2
    return 1
  fi

  method="$(docker image inspect "$base" --format '{{ index .Config.Labels "hardening.method" }}' 2>/dev/null || true)"
  profile="$(docker image inspect "$base" --format '{{ index .Config.Labels "hardening.profile" }}' 2>/dev/null || true)"
  if [[ "$method" != "$EXPECTED_MODE" ]]; then
    echo "[reuse] Hardened base mode mismatch. Expected '$EXPECTED_MODE', found '$method'." >&2
    return 1
  fi
  if [[ "$profile" != 'cis_level1_server' ]]; then
    echo "[reuse] Hardened base profile mismatch. Expected 'cis_level1_server', found '$profile'." >&2
    return 1
  fi

  echo '[reuse] Existing hardened base passed validation.'
  echo "[reuse] BASE_IMAGE = $base"
  return 0
}

full_resolve_and_harden(){
  echo '[build] Running full resolver + hardened-base build path.'
  bash scripts/supply-chain/resolve-base-digests.sh --write
  bash scripts/supply-chain/resolve-tool-artifacts.sh --write

  # Read the fully validated resolver output and preserve the immutable upstream
  # Ubuntu digest as the input to the hardening builder.
  BUILD_ENV_FILE="$BUILD_ENV" source scripts/common/load-build-env.sh >/dev/null
  local source_image="$BASE_IMAGE"

  if [[ "$EXPECTED_MODE" == 'poc' ]]; then
    bash scripts/hardening/build-hardened-base.sh --sandbox-type poc --source-image "$source_image"
  else
    [[ -n "$TOKEN" ]] || { echo 'ERROR: Ubuntu Pro token is required because the Production hardened base must be rebuilt.' >&2; exit 2; }
    UBUNTU_PRO_TOKEN="$TOKEN" bash scripts/hardening/build-hardened-base.sh --sandbox-type "$TYPE" --source-image "$source_image"
  fi

  apply_hardened_env
  update_package_version
}

if [[ -n "$BUILD_ENV_SOURCE" ]]; then
  [[ -f "$BUILD_ENV_SOURCE" ]] || { echo "ERROR: build env source not found: $BUILD_ENV_SOURCE" >&2; exit 2; }
  src_abs="$(cd "$(dirname "$BUILD_ENV_SOURCE")" && pwd)/$(basename "$BUILD_ENV_SOURCE")"
  dst_abs="$BUILD_ENV"
  if [[ "$src_abs" != "$dst_abs" ]]; then
    cp "$BUILD_ENV_SOURCE" "$BUILD_ENV"
    echo "[INFO] Copied existing build configuration: $BUILD_ENV_SOURCE -> $BUILD_ENV"
  fi
fi

if [[ ! -f "$BUILD_ENV" ]]; then
  cp .build.env.example "$BUILD_ENV"
  echo '[INFO] Created .build.env from .build.env.example.'
fi
update_package_version

USING_REUSED=false
if [[ "$REUSE" == true ]]; then
  if can_reuse_hardened_base; then
    USING_REUSED=true
    echo '[reuse] Skipping upstream base-image resolution and hardened-base generation for this iterative build.'
    echo '[reuse] Refreshing and pinning the current ucode main commit required for headless PAT support...'
    bash scripts/supply-chain/resolve-tool-artifacts.sh --write --ucode-only
  else
    echo '[reuse] Reuse requirements were not met. Falling back automatically to a new hardened-base build.' >&2
  fi
fi

if [[ "$USING_REUSED" != true ]]; then
  full_resolve_and_harden
fi

validate_build_env

if [[ "$EXPECTED_MODE" == 'poc' ]]; then
  echo '=== Admin build: POC / self-hardened Ubuntu 24.04 ==='
  [[ "$USING_REUSED" == true ]] && echo '[reuse] POC hardened base reused.'
  SKIP_CIS_ASSESSMENT="$SKIP_CIS" bash scripts/poc/build-and-export.sh
  echo '[OK] Admin POC bundle is ready under poc/images/. Developer runs scripts/poc/load-and-start.*'
else
  echo "=== Admin build: $TYPE / Ubuntu Pro + USG ==="
  [[ "$USING_REUSED" == true ]] && echo '[reuse] Production hardened base reused; Ubuntu Pro hardening was not rerun.'
  REQUIRE_CIS_PASS=true bash scripts/platform/02-setup-ecr.sh
  echo '[OK] Admin Production images are in ECR and the central approved-image manifest is published to SSM.'
fi
