#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Builds the selected hardened Ubuntu 24.04 base: POC self-hardening or non-POC Ubuntu Pro + USG.
# Admin maintenance: Application package changes do not belong here. Modify only hardening inputs, profiles, evidence generation, or base-image security controls.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# build-hardened-base.sh
#
# Builds ONE hardened Ubuntu 24.04 base image, selected by --sandbox-type:
#
#   poc        -> self-hardened image (OpenSCAP auto-remediation against the
#                 cis_level1_server profile). No Ubuntu Pro subscription
#                 required. Matches the "OpenSCAP hardened" branch validated
#                 in Images_Compare_Script_test/Run-ImageTest.ps1.
#
#   any non-POC SandboxType -> Ubuntu Pro + USG (Ubuntu Security Guide) hardened
#                 image. Requires a valid Ubuntu Pro token. Matches the "USG
#                 hardened" branch validated in the same reference script.
#
# The resulting image is intentionally generic (OS-level hardening only, no
# Node/Python/AI CLI/Squid packages). It is meant to be pushed to a registry
# and then referenced as BOTH:
#   BASE_IMAGE=<pushed-ref>@sha256:<digest>          (.devcontainer/Dockerfile)
#   SQUID_BASE_IMAGE=<pushed-ref>@sha256:<digest>     (squid/Dockerfile)
# in .build.env, so the devcontainer and the Squid egress proxy inherit the
# EXACT SAME hardened OS layer, satisfying the "same hardening policy for
# both containers" requirement.
#
# This script only produces the hardened base layer. It does not modify or
# replace .devcontainer/Dockerfile, .devcontainer/cis-level1-harden.sh, or
# squid/Dockerfile — those keep doing their existing application-level work
# (Node/AI CLIs, non-root user, squid config, etc.) unchanged, FROM this new
# base.
#
# All comments and output are in English by design.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Defaults
# ---------------------------------------------------------------------------
SANDBOX_TYPE=""
UBUNTU_PRO_TOKEN="${UBUNTU_PRO_TOKEN:-}"
SOURCE_IMAGE="ubuntu:24.04"
REGISTRY=""
IMAGE_REPO_NAME="ai-sandbox-hardened-base"
TAG=""
SSG_URL_ARG=""
SSG_SHA256_ARG=""
COMPLIANCE_DATA_STREAM_PATH=""
BUILD_ENV_FILE=""
WORK_DIR="$(pwd)/hardened-base-build"
SKIP_PUSH=0
KEEP_CONTAINERS=0
REFRESH_COMPLIANCE_CONTENT=0
LOCAL_REGISTRY_PORT=5000
# Admin-host-only scratch registry used purely to obtain a real digest for
# the hardened base image. Never used for developer distribution.
LOCAL_REGISTRY_NAME="ai-sandbox-hardened-base-digest-scratch-registry"

# ---------------------------------------------------------------------------
# 1. Argument parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  build-hardened-base.sh --sandbox-type <value> [options]

Required:
  --sandbox-type <value>            Selects the hardening method.
                                       POC         -> OpenSCAP self-hardening
                                       any non-POC -> Ubuntu Pro + USG hardening

Options:
  --ubuntu-pro-token <token>        Required for any non-POC SandboxType.
                                     Falls back to $UBUNTU_PRO_TOKEN env var.
  --source-image <ref>              Starting OS image (default: ubuntu:24.04).
                                     Pass a digest-pinned reference from
                                     resolve-base-digests.sh for a fully
                                     reproducible build, e.g.
                                     ubuntu:24.04@sha256:....
  --registry <host[:port]/repo>     Optional. Push the hardened BASE image to
                                     a shared registry instead of the
                                     disposable local one — only useful if
                                     you reuse this base image across
                                     multiple admin build hosts. NOT required
                                     for either poc or production: it exists
                                     only so this script can obtain a real
                                     registry digest to satisfy .build.env's
                                     existing "BASE_IMAGE must be
                                     repo@sha256:..." validation (a plain
                                     `docker commit` result has no digest
                                     until it is pushed somewhere). If
                                     omitted, an ephemeral, admin-host-only
                                     "digest resolution scratch registry" is
                                     started on 127.0.0.1:<--local-registry-port>.
                                     Developers never see or use this scratch
                                     registry, and it has nothing to do with
                                     how the FINAL devcontainer/squid/
                                     runtime images reach developers — that
                                     is still tar export for POC / ECR push
                                     for Production via the existing
                                     scripts/poc/build-and-export.sh and
                                     scripts/ecr/deploy-ecr.*, unchanged.
  --image-name <name>               Image repo name (default: ai-sandbox-hardened-base)
  --tag <tag>                       Image tag (default: <type>-24.04-<UTC date>)
  --ssg-url <url>                   Pinned ComplianceAsCode SSG bundle URL.
                                     Defaults to SSG_URL from .build.env if present.
  --ssg-sha256 <hex64>               SHA-256 of the SSG bundle above.
                                     Defaults to SSG_SHA256 from .build.env.
  --compliance-data-stream-path <p> Use a local ssg-ubuntu2404-ds.xml directly
                                     instead of downloading (highest priority).
  --build-env-file <path>           Path to .build.env to read SSG_URL/SSG_SHA256
                                     from (default: <repo-root>/.build.env).
  --work-dir <path>                 Scratch/output directory
                                     (default: ./hardened-base-build).
  --skip-push                       Build and commit locally only. The
                                     resulting image will NOT be digest-pinned
                                     and CANNOT be used directly as BASE_IMAGE /
                                     SQUID_BASE_IMAGE (those require an
                                     "@sha256:" registry digest). Use only to
                                     inspect/debug the hardened image locally.
  --local-registry-port <port>      Port for the ephemeral local registry
                                     (default: 5000).
  --keep-containers                 Do not remove build/test containers on exit.
  --refresh-compliance-content      Download the LATEST ComplianceAsCode
                                     release from GitHub instead of requiring
                                     a pinned SSG_URL/SSG_SHA256. This breaks
                                     supply-chain pinning; use only for
                                     one-off local experimentation.
  -h, --help                        Show this help.

Examples:
  # POC self-hardening (OpenSCAP), digest resolved via the local scratch registry
  ./build-hardened-base.sh --sandbox-type poc

  # Production hardening (Ubuntu Pro + USG) — still no --registry needed;
  # the FINAL images (not this base) go to ECR later via deploy-ecr.*
  ./build-hardened-base.sh --sandbox-type production \
      --ubuntu-pro-token "C-xxxxxxxxxxxxxxxxxxxxxxxx"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox-type) SANDBOX_TYPE="${2:-}"; shift 2 ;;
    --ubuntu-pro-token) UBUNTU_PRO_TOKEN="${2:-}"; shift 2 ;;
    --source-image) SOURCE_IMAGE="${2:-}"; shift 2 ;;
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --image-name) IMAGE_REPO_NAME="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --ssg-url) SSG_URL_ARG="${2:-}"; shift 2 ;;
    --ssg-sha256) SSG_SHA256_ARG="${2:-}"; shift 2 ;;
    --compliance-data-stream-path) COMPLIANCE_DATA_STREAM_PATH="${2:-}"; shift 2 ;;
    --build-env-file) BUILD_ENV_FILE="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --skip-push) SKIP_PUSH=1; shift ;;
    --local-registry-port) LOCAL_REGISTRY_PORT="${2:-}"; shift 2 ;;
    --keep-containers) KEEP_CONTAINERS=1; shift ;;
    --refresh-compliance-content) REFRESH_COMPLIANCE_CONTENT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

REQUESTED_SANDBOX_TYPE="$(printf '%s' "$SANDBOX_TYPE" | tr '[:upper:]' '[:lower:]')"
[[ -n "$REQUESTED_SANDBOX_TYPE" ]] || { echo 'ERROR: --sandbox-type is required' >&2; usage; exit 1; }
if [[ "$REQUESTED_SANDBOX_TYPE" == "poc" ]]; then SANDBOX_TYPE=poc; else SANDBOX_TYPE=production; fi
echo "[policy] requested SandboxType='$REQUESTED_SANDBOX_TYPE' -> hardening='$SANDBOX_TYPE'"

if [[ -z "$TAG" ]]; then
  TAG="${SANDBOX_TYPE}-24.04-$(date -u +%Y%m%d)"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Best-effort: repo root is two levels above scripts/hardening/.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd 2>/dev/null || echo "$SCRIPT_DIR")"
if [[ -z "$BUILD_ENV_FILE" ]]; then
  BUILD_ENV_FILE="$REPO_ROOT/.build.env"
fi

COMMON_IMAGE="ai-sandbox-hardening-common:build"
RAW_IMAGE="ai-sandbox-hardening-raw:${SANDBOX_TYPE}"
BUILD_CONTAINER="ai-sandbox-hardening-builder"

echo "=============================================================================="
echo " AI Sandbox — Hardened Base Image Builder"
echo "=============================================================================="
echo "  sandbox type   : $SANDBOX_TYPE"
echo "  source image   : $SOURCE_IMAGE"
echo "  work dir       : $WORK_DIR"
echo "  image name:tag : $IMAGE_REPO_NAME:$TAG"
echo "=============================================================================="

# ---------------------------------------------------------------------------
# 2. Preflight
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found in PATH." >&2; exit 1; }

os_type="$(docker info --format '{{.OSType}}' 2>/dev/null || true)"
if [[ "$os_type" != "linux" ]]; then
  echo "ERROR: Docker must be running Linux containers (found: '${os_type:-unknown}')." >&2
  exit 1
fi

if [[ "$SANDBOX_TYPE" == "production" && -z "$UBUNTU_PRO_TOKEN" ]]; then
  echo "" >&2
  echo "Ubuntu Pro token is required for --sandbox-type production." >&2
  read -r -s -p "Enter Ubuntu Pro token (hidden): " UBUNTU_PRO_TOKEN
  echo "" >&2
  [[ -n "$UBUNTU_PRO_TOKEN" ]] || { echo "ERROR: Ubuntu Pro token not supplied." >&2; exit 1; }
fi

mkdir -p "$WORK_DIR/context" "$WORK_DIR/results"

# ---------------------------------------------------------------------------
# 3. Resolve pinned ComplianceAsCode (SSG) content
# ---------------------------------------------------------------------------
read_env_value() {
  # Reads KEY=VALUE from a simple .build.env-style file without executing it.
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  grep -E "^[[:space:]]*${key}=" "$file" | tail -n1 | cut -d'=' -f2- | tr -d '\r'
}

SSG_URL="$SSG_URL_ARG"
SSG_SHA256="$SSG_SHA256_ARG"
if [[ -z "$SSG_URL" ]]; then SSG_URL="$(read_env_value "$BUILD_ENV_FILE" SSG_URL || true)"; fi
if [[ -z "$SSG_SHA256" ]]; then SSG_SHA256="$(read_env_value "$BUILD_ENV_FILE" SSG_SHA256 || true)"; fi

SCAP_XML="$WORK_DIR/context/ssg-ubuntu2404-ds.xml"

if [[ -n "$COMPLIANCE_DATA_STREAM_PATH" ]]; then
  echo "[3/10] Using local compliance data stream: $COMPLIANCE_DATA_STREAM_PATH"
  [[ -f "$COMPLIANCE_DATA_STREAM_PATH" ]] || { echo "ERROR: file not found: $COMPLIANCE_DATA_STREAM_PATH" >&2; exit 1; }
  cp -f "$COMPLIANCE_DATA_STREAM_PATH" "$SCAP_XML"

elif [[ -n "$SSG_URL" && -n "$SSG_SHA256" ]]; then
  echo "[3/10] Downloading pinned SSG content: $SSG_URL"
  archive="$WORK_DIR/context/_ssg-download"
  mkdir -p "$archive"
  curl -fsSL "$SSG_URL" -o "$archive/ssg.zip"
  actual_sha256="$(sha256sum "$archive/ssg.zip" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$SSG_SHA256" ]]; then
    echo "ERROR: SSG bundle SHA-256 mismatch." >&2
    echo "  expected: $SSG_SHA256" >&2
    echo "  actual  : $actual_sha256" >&2
    exit 1
  fi
  unzip -q -o "$archive/ssg.zip" -d "$archive/extract"
  found="$(find "$archive/extract" -type f -name 'ssg-ubuntu2404-ds.xml' | head -n1)"
  [[ -n "$found" ]] || { echo "ERROR: ssg-ubuntu2404-ds.xml not found inside SSG bundle." >&2; exit 1; }
  cp -f "$found" "$SCAP_XML"

elif [[ "$REFRESH_COMPLIANCE_CONTENT" -eq 1 ]]; then
  echo "[3/10] WARNING: --refresh-compliance-content breaks supply-chain pinning." >&2
  echo "              Downloading the LATEST ComplianceAsCode release from GitHub..." >&2
  api_response="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/ComplianceAsCode/content/releases/latest)"
  asset_url="$(printf '%s' "$api_response" \
    | grep -Eo '"browser_download_url":[[:space:]]*"[^"]*scap-security-guide-[^"]*\.zip"' \
    | grep -v '\.sha512' | head -n1 | sed -E 's/.*"(https[^"]+)"/\1/')"
  [[ -n "$asset_url" ]] || { echo "ERROR: could not find a pre-built scap-security-guide zip in the latest release." >&2; exit 1; }
  archive="$WORK_DIR/context/_ssg-download"
  mkdir -p "$archive"
  curl -fsSL "$asset_url" -o "$archive/ssg.zip"
  unzip -q -o "$archive/ssg.zip" -d "$archive/extract"
  found="$(find "$archive/extract" -type f -name 'ssg-ubuntu2404-ds.xml' | head -n1)"
  [[ -n "$found" ]] || { echo "ERROR: ssg-ubuntu2404-ds.xml not found after extracting latest release." >&2; exit 1; }
  cp -f "$found" "$SCAP_XML"

else
  cat >&2 <<'EOF'
ERROR: No pinned ComplianceAsCode content available.

Provide one of:
  --compliance-data-stream-path <path-to-ssg-ubuntu2404-ds.xml>
  --ssg-url <url> --ssg-sha256 <hex64>
  (or make sure SSG_URL / SSG_SHA256 already exist in .build.env)
  --refresh-compliance-content   (breaks pinning; local experimentation only)
EOF
  exit 1
fi

echo "  [OK] SSG content ready: $SCAP_XML"

# ---------------------------------------------------------------------------
# 4. Write build context (Dockerfiles + scripts)
# ---------------------------------------------------------------------------
CTX="$WORK_DIR/context"

cat > "$CTX/install-common.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bash ca-certificates coreutils curl file findutils grep jq less \
  openssh-client procps openscap-scanner libxml2-utils tar unzip xz-utils
rm -rf /var/lib/apt/lists/*
EOS

cat > "$CTX/find-profile.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
DS="/opt/ssg/ssg-ubuntu2404-ds.xml"
oscap info "$DS" 2>/dev/null | awk '/^[[:space:]]*Id:[[:space:]].*cis_level1_server/ {print $2; exit}'
EOS

cat > "$CTX/audit.sh" <<'EOS'
#!/usr/bin/env bash
# Read-only OpenSCAP evidence audit. Never mutates the filesystem.
set +e
PHASE="${1:-final}"
DS="/opt/ssg/ssg-ubuntu2404-ds.xml"
PROFILE="$(/opt/hardening/find-profile.sh)"
mkdir -p /results
LOG="/results/${PHASE}-audit.log"
ARF="/results/${PHASE}-results-arf.xml"
HTML="/results/${PHASE}-report.html"

if [ -z "$PROFILE" ]; then
  echo "CIS Level 1 Server profile not found" > "$LOG"
  echo "99" > "/results/${PHASE}-audit-exit-code.txt"
  exit 0
fi

echo "Profile: $PROFILE" > "$LOG"
oscap xccdf eval --profile "$PROFILE" --results-arf "$ARF" --report "$HTML" "$DS" >> "$LOG" 2>&1
echo "$?" > "/results/${PHASE}-audit-exit-code.txt"
exit 0
EOS

cat > "$CTX/harden-openscap.sh" <<'EOS'
#!/usr/bin/env bash
# POC self-hardening: OpenSCAP automatic remediation against cis_level1_server.
set +e
mkdir -p /results
DS="/opt/ssg/ssg-ubuntu2404-ds.xml"
PROFILE="$(/opt/hardening/find-profile.sh)"
LOG="/results/openscap-remediation.log"

if [ -z "$PROFILE" ]; then
  echo "CIS Level 1 Server profile not found" | tee "$LOG"
  echo "99" > /results/remediation-exit-code.txt
  exit 99
fi

echo "OpenSCAP self-hardening" | tee "$LOG"
echo "Profile: $PROFILE" | tee -a "$LOG"
echo "Started: $(date -Iseconds)" | tee -a "$LOG"

oscap xccdf eval --profile "$PROFILE" \
  --results /results/before-results.xml --report /results/before-report.html \
  "$DS" >> "$LOG" 2>&1
echo "$?" > /results/baseline-audit-exit-code.txt

# Reviewable evidence: the generated remediation script itself.
oscap xccdf generate fix --fix-type bash --profile "$PROFILE" "$DS" \
  > /results/generated-full-profile-fix.sh 2>> "$LOG"
fixgen_rc=$?
if [[ "$fixgen_rc" -ne 0 ]]; then
  echo "OpenSCAP fix generation failed with exit code: $fixgen_rc" | tee -a "$LOG"
  exit "$fixgen_rc"
fi

oscap xccdf eval --remediate --profile "$PROFILE" \
  --results-arf /results/remediation-results-arf.xml \
  --report /results/remediation-report.html \
  "$DS" >> "$LOG" 2>&1
rem_rc=$?
echo "$rem_rc" > /results/remediation-exit-code.txt

oscap xccdf eval --profile "$PROFILE" \
  --results-arf /results/after-results-arf.xml \
  --report /results/after-report.html \
  "$DS" >> "$LOG" 2>&1
audit_rc=$?
echo "$audit_rc" > /results/post-audit-exit-code.txt

echo "Finished: $(date -Iseconds)" | tee -a "$LOG"
echo "Remediation exit code: $rem_rc" | tee -a "$LOG"
echo "Post-remediation audit exit code: $audit_rc" | tee -a "$LOG"
# OpenSCAP uses 2 when evaluation completes with failed rules. Any other non-zero
# value indicates an execution/remediation engine failure and must stop the build.
if [[ "$rem_rc" -ne 0 && "$rem_rc" -ne 2 ]]; then exit "$rem_rc"; fi
if [[ "$audit_rc" -ne 0 && "$audit_rc" -ne 2 ]]; then exit "$audit_rc"; fi
exit 0
EOS

cat > "$CTX/harden-usg.sh" <<'EOS'
#!/usr/bin/env bash
# Production hardening: Ubuntu Pro / USG fix against cis_level1_server.
set +e
mkdir -p /results
LOG="/results/usg-fix.log"

echo "USG CIS Level 1 Server hardening" | tee "$LOG"
echo "Started: $(date -Iseconds)" | tee -a "$LOG"

usg audit cis_level1_server >> "$LOG" 2>&1
echo "$?" > /results/baseline-audit-exit-code.txt

echo "" | tee -a "$LOG"
echo "Running: usg fix cis_level1_server" | tee -a "$LOG"
usg fix cis_level1_server >> "$LOG" 2>&1
fix_rc=$?
echo "$fix_rc" > /results/fix-exit-code.txt

echo "" | tee -a "$LOG"
echo "Post-fix audit" | tee -a "$LOG"
usg audit cis_level1_server >> "$LOG" 2>&1
audit_rc=$?
echo "$audit_rc" > /results/post-audit-exit-code.txt

if [ -d /var/lib/usg ]; then
  mkdir -p /results/usg-reports
  cp -a /var/lib/usg/. /results/usg-reports/ 2>/dev/null
fi

echo "Finished: $(date -Iseconds)" | tee -a "$LOG"
echo "USG fix exit code: $fix_rc" | tee -a "$LOG"
echo "USG post audit exit code: $audit_rc" | tee -a "$LOG"
# A failed USG remediation command is a build failure. The post-audit result is
# evidence only; container-inapplicable host rules are handled by the separate
# release compliance gate and approved tailoring process.
if [[ "$fix_rc" -ne 0 ]]; then exit "$fix_rc"; fi
exit 0
EOS

cat > "$CTX/cleanup-toolchain.sh" <<'EOS'
#!/usr/bin/env bash
# Strips the hardening/scanning toolchain out of the FINAL committed image.
# The scanner and SSG content are only needed during the build/audit step;
# shipping them in every downstream (devcontainer/squid) image would add
# unnecessary weight and attack surface.
set -e
apt-get purge -y --auto-remove openscap-scanner libxml2-utils ubuntu-pro-client usg usg-benchmarks-1 2>/dev/null || true
rm -rf /opt/hardening /opt/ssg /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/locale/* 2>/dev/null || true
exit 0
EOS

cat > "$CTX/Dockerfile.common" <<EOF
FROM ${SOURCE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
COPY install-common.sh /opt/hardening/install-common.sh
RUN chmod +x /opt/hardening/install-common.sh && /opt/hardening/install-common.sh
COPY ssg-ubuntu2404-ds.xml /opt/ssg/ssg-ubuntu2404-ds.xml
COPY find-profile.sh /opt/hardening/find-profile.sh
COPY audit.sh /opt/hardening/audit.sh
COPY harden-openscap.sh /opt/hardening/harden-openscap.sh
COPY harden-usg.sh /opt/hardening/harden-usg.sh
RUN chmod +x /opt/hardening/*.sh
WORKDIR /
CMD ["sleep", "infinity"]
EOF

cat > "$CTX/Dockerfile.production" <<'EOF'
# syntax=docker/dockerfile:1.7
FROM ai-sandbox-hardening-common:build
RUN --mount=type=secret,id=pro-attach-config \
    bash -euxo pipefail -c '\
      apt-get update; \
      apt-get install -y --no-install-recommends ubuntu-pro-client ca-certificates; \
      pro attach --attach-config /run/secrets/pro-attach-config; \
      pro enable usg; \
      apt-get update; \
      apt-get install -y --no-install-recommends usg usg-benchmarks-1; \
      pro detach --assume-yes; \
      rm -rf /var/lib/apt/lists/*'
WORKDIR /
CMD ["sleep", "infinity"]
EOF

# NOTE: no extra copy of the SCAP data stream is needed here.
# SCAP_XML and CTX both resolve to the same context path, so the data stream
# acquired in step 3 is already available to the Docker build.

# ---------------------------------------------------------------------------
# 5. Build common + raw candidate image
# ---------------------------------------------------------------------------
export DOCKER_BUILDKIT=1

echo "[4/10] Building common base (OS + OpenSCAP scanner + pinned SSG content)..."
docker build --progress=plain -f "$CTX/Dockerfile.common" -t "$COMMON_IMAGE" "$CTX"

SECRET_FILE=""
cleanup() {
  if [[ "$KEEP_CONTAINERS" -ne 1 ]]; then
    docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SECRET_FILE" && -f "$SECRET_FILE" ]]; then
    rm -f "$SECRET_FILE"
  fi
  UBUNTU_PRO_TOKEN=""
}
trap cleanup EXIT

if [[ "$SANDBOX_TYPE" == "poc" ]]; then
  echo "[5/10] Building POC raw candidate (no Ubuntu Pro dependency)..."
  docker build --progress=plain -f "$CTX/Dockerfile.common" -t "$RAW_IMAGE" "$CTX"
else
  echo "[5/10] Building Production raw candidate (Ubuntu Pro attach + USG install)..."
  SECRET_FILE="$(mktemp)"
  cat > "$SECRET_FILE" <<EOF
token: $UBUNTU_PRO_TOKEN
enable_services:
  - usg
EOF
  docker build --progress=plain \
    --secret "id=pro-attach-config,src=$SECRET_FILE" \
    -f "$CTX/Dockerfile.production" -t "$RAW_IMAGE" "$CTX"
fi

# ---------------------------------------------------------------------------
# 6. Harden, audit, and commit
# ---------------------------------------------------------------------------
docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$BUILD_CONTAINER" "$RAW_IMAGE" >/dev/null

echo "[6/10] Applying hardening (${SANDBOX_TYPE})..."
if [[ "$SANDBOX_TYPE" == "poc" ]]; then
  docker exec "$BUILD_CONTAINER" bash /opt/hardening/harden-openscap.sh
else
  docker exec "$BUILD_CONTAINER" bash /opt/hardening/harden-usg.sh
fi

echo "[7/10] Running final read-only OpenSCAP evidence audit..."
docker exec "$BUILD_CONTAINER" bash /opt/hardening/audit.sh final || true
docker cp "${BUILD_CONTAINER}:/results/." "$WORK_DIR/results" 2>/dev/null || true

echo "[8/10] Stripping the scanning/hardening toolchain from the final image..."
docker cp "$CTX/cleanup-toolchain.sh" "${BUILD_CONTAINER}:/tmp/cleanup-toolchain.sh"
docker exec "$BUILD_CONTAINER" bash -c "chmod +x /tmp/cleanup-toolchain.sh && /tmp/cleanup-toolchain.sh && rm -f /tmp/cleanup-toolchain.sh"

echo "[9/10] Committing hardened filesystem -> ${IMAGE_REPO_NAME}:${TAG}"
docker commit \
  --change 'CMD ["sleep", "infinity"]' \
  --change "LABEL hardening.method=${SANDBOX_TYPE} hardening.profile=cis_level1_server hardening.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$BUILD_CONTAINER" "${IMAGE_REPO_NAME}:${TAG}" >/dev/null

# ---------------------------------------------------------------------------
# 7. Push and resolve a real registry digest
# ---------------------------------------------------------------------------
if [[ "$SKIP_PUSH" -eq 1 ]]; then
  echo "[10/10] --skip-push set: image left local-only as ${IMAGE_REPO_NAME}:${TAG}"
  echo "        NOTE: this image has NO registry digest and cannot be used as"
  echo "        BASE_IMAGE / SQUID_BASE_IMAGE in .build.env (digest pin required)."
  FINAL_REF="${IMAGE_REPO_NAME}:${TAG}"
  DIGEST=""
else
  if [[ -z "$REGISTRY" ]]; then
    echo "[10/10] No --registry given: starting an admin-host-only DIGEST"
    echo "         RESOLUTION SCRATCH REGISTRY (not a distribution channel)."
    echo "         Developers never see or use this. It exists solely so this"
    echo "         script can obtain a real 'repo@sha256:...' digest to satisfy"
    echo "         .build.env's existing digest-pinning validation. The actual"
    echo "         POC developer hand-off is still the unchanged tar export/"
    echo "         load flow (build-and-export.sh / load-and-start.sh)."
    if ! docker ps --format '{{.Names}}' | grep -qx "$LOCAL_REGISTRY_NAME"; then
      docker rm -f "$LOCAL_REGISTRY_NAME" >/dev/null 2>&1 || true
      docker run -d --name "$LOCAL_REGISTRY_NAME" -p "${LOCAL_REGISTRY_PORT}:5000" registry:2 >/dev/null
      sleep 2
    fi
    REGISTRY="localhost:${LOCAL_REGISTRY_PORT}"
  fi

  FINAL_REF="${REGISTRY}/${IMAGE_REPO_NAME}:${TAG}"
  echo "[10/10] Tagging and pushing: $FINAL_REF"
  docker tag "${IMAGE_REPO_NAME}:${TAG}" "$FINAL_REF"
  docker push "$FINAL_REF"

  DIGEST="$(docker image inspect "$FINAL_REF" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed -n 's/.*@\(sha256:[0-9a-f]*\)$/\1/p')"
  if [[ -z "$DIGEST" ]]; then
    DIGEST="$(docker buildx imagetools inspect "$FINAL_REF" --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"')"
  fi
  if [[ -z "$DIGEST" ]]; then
    echo "ERROR: could not resolve a registry digest for $FINAL_REF after push." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 8. Emit ready-to-paste .build.env lines
# ---------------------------------------------------------------------------
ENV_OUT="$WORK_DIR/hardened-base.env"
if [[ -n "$DIGEST" ]]; then
  # Strip only the trailing ":<tag>" (last colon), NOT the registry's own
  # "host:port" colon — e.g. "localhost:5000/repo:tag" must become
  # "localhost:5000/repo", not "localhost".
  REPO_ONLY="${FINAL_REF%:*}"
  PINNED_REF="${REPO_ONLY}@${DIGEST}"
  cat > "$ENV_OUT" <<EOF
# Generated by build-hardened-base.sh — sandbox type: ${SANDBOX_TYPE}
BASE_IMAGE=${PINNED_REF}
SQUID_BASE_IMAGE=${PINNED_REF}
EOF
else
  cat > "$ENV_OUT" <<EOF
# --skip-push was used — no digest available. Push to a registry and re-run
# without --skip-push before updating .build.env.
# local image: ${IMAGE_REPO_NAME}:${TAG}
EOF
fi

echo "=============================================================================="
echo " DONE"
echo "=============================================================================="
echo "  Hardened image : ${IMAGE_REPO_NAME}:${TAG}"
[[ -n "${DIGEST:-}" ]] && echo "  Pushed ref     : $PINNED_REF"
echo "  Evidence dir   : $WORK_DIR/results"
echo "  Env snippet    : $ENV_OUT"
echo ""
echo "Next steps:"
echo "  1. Review $WORK_DIR/results (final-report.html, final-*.log)."
echo "  2. Copy the two lines from $ENV_OUT into .build.env (replacing the"
echo "     existing BASE_IMAGE / SQUID_BASE_IMAGE values)."
echo "  3. Run: bash scripts/poc/build-and-export.sh"
echo "=============================================================================="
