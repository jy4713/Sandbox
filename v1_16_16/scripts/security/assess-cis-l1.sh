#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Admin offline CIS Level 1 evidence scan of the final devcontainer image using pinned OpenSCAP content.
# Admin maintenance: Application changes should not alter this script unless they require an approved CIS tailoring change or assessment workflow change.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=/dev/null
source "$ROOT/scripts/common/load-build-env.sh"

IMAGE="${1:-sandbox/devcontainer:v1}"
REPORT_DIR="${CIS_REPORT_DIR:-$ROOT/security/reports}"
SCANNER_IMAGE="sandbox/cis-scanner:${SANDBOX_VERSION:-v1.16.16}"
PROFILE="${CIS_PROFILE_ID:-xccdf_org.ssgproject.content_profile_cis_level1_server}"
REQUIRE_PASS="${REQUIRE_CIS_PASS:-false}"

mkdir -p "$REPORT_DIR"
rm -f "$REPORT_DIR"/cis-l1-report.html "$REPORT_DIR"/cis-l1-results-arf.xml "$REPORT_DIR"/cis-l1-results.xml "$REPORT_DIR"/cis-scan-metadata.txt

echo "[cis] Building pinned OpenSCAP scanner..."
docker build --no-cache \
  -f "$ROOT/security/cis-scanner/Dockerfile" \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg SSG_URL="$SSG_URL" \
  --build-arg SSG_SHA256="$SSG_SHA256" \
  -t "$SCANNER_IMAGE" "$ROOT/security/cis-scanner"

if ! docker run --rm --entrypoint oscap "$SCANNER_IMAGE" info /opt/ssg/ssg-ubuntu2404-ds.xml 2>/dev/null | grep -Fq "$PROFILE"; then
  echo "ERROR: CIS profile '$PROFILE' was not found in pinned SSG content." >&2
  echo "Available CIS-related profiles:" >&2
  docker run --rm --entrypoint oscap "$SCANNER_IMAGE" info /opt/ssg/ssg-ubuntu2404-ds.xml 2>/dev/null | grep -i cis >&2 || true
  exit 1
fi

cid=""
volume_name=""
tar_path="$(mktemp "${TMPDIR:-/tmp}/ai-sandbox-rootfs-XXXXXX.tar")"
cleanup() {
  [[ -n "$cid" ]] && docker rm -f "$cid" >/dev/null 2>&1 || true
  [[ -n "$volume_name" ]] && docker volume rm -f "$volume_name" >/dev/null 2>&1 || true
  rm -f "$tar_path"
}
trap cleanup EXIT

cid="$(docker create "$IMAGE")"
echo "[cis] Exporting final Golden Image root filesystem..."
docker export "$cid" -o "$tar_path"

volume_name="ai-sandbox-cis-rootfs-$(date +%s)-$$"
docker volume create "$volume_name" >/dev/null

echo "[cis] Extracting root filesystem inside Linux Docker storage..."
docker run --rm \
  -v "$volume_name:/target" \
  -v "$tar_path:/tmp/rootfs.tar:ro" \
  --entrypoint /bin/sh \
  "$SCANNER_IMAGE" \
  -c 'set -eu; tar -xf /tmp/rootfs.tar -C /target'

docker_args=(run --rm -e OSCAP_PROBE_ROOT=/target -v "$volume_name:/target:ro" -v "$REPORT_DIR:/reports")
oscap_args=(xccdf eval --profile "$PROFILE" --results /reports/cis-l1-results.xml --results-arf /reports/cis-l1-results-arf.xml --report /reports/cis-l1-report.html)
if [[ -f "$ROOT/security/cis-tailoring.xml" ]]; then
  docker_args+=( -v "$ROOT/security/cis-tailoring.xml:/tailoring.xml:ro" )
  oscap_args+=( --tailoring-file /tailoring.xml )
fi
oscap_args+=( /opt/ssg/ssg-ubuntu2404-ds.xml )

set +e
docker "${docker_args[@]}" "$SCANNER_IMAGE" "${oscap_args[@]}"
rc=$?
set -e

cat > "$REPORT_DIR/cis-scan-metadata.txt" <<META
sandbox_version=${SANDBOX_VERSION:-v1.16.16}
image=$IMAGE
image_id=$(docker image inspect "$IMAGE" --format '{{.Id}}')
profile=$PROFILE
ssg_version=$SSG_VERSION
assessment_engine=OpenSCAP
assessment_content=ComplianceAsCode
assessment_scope=offline exported container root filesystem in temporary Docker volume
scanner_exit_code=$rc
require_cis_pass=$REQUIRE_PASS
scan_time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META

case "$rc" in
  0) echo "[cis] PASS: OpenSCAP evaluation completed without selected-rule failures." ;;
  2)
    if [[ "$REQUIRE_PASS" == "true" ]]; then
      echo "ERROR: OpenSCAP found selected-rule failures and REQUIRE_CIS_PASS=true." >&2
      exit 2
    fi
    echo "[cis] WARNING: OpenSCAP completed with selected-rule failures." >&2
    echo "[cis] Review the report and approved container tailoring/exceptions before release." >&2
    ;;
  *) echo "ERROR: OpenSCAP assessment failed operationally (exit $rc)." >&2; exit "$rc" ;;
esac

for f in cis-l1-report.html cis-l1-results.xml cis-l1-results-arf.xml; do
  [[ -s "$REPORT_DIR/$f" ]] || { echo "ERROR: $f was not generated" >&2; exit 1; }
done
