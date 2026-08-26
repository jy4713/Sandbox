#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Admin POC build workflow for the two sandbox images: DevContainer and Squid.
# Admin maintenance: Update only when the approved image set or POC bundle format changes.
# Safety rule: keep runtime policy hashes and image IDs synchronized with the delivered bundle.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
source "$ROOT/scripts/common/load-build-env.sh"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
TARGET="${DEVCONTAINER_TARGET:-baseline}"; VERSION="${SANDBOX_VERSION:-v1.16.16}"; IMAGES_DIR="$ROOT/poc/images"
[[ "$BASE_IMAGE" == "$SQUID_BASE_IMAGE" ]] || { echo 'ERROR: BASE_IMAGE and SQUID_BASE_IMAGE must be identical' >&2; exit 1; }
rm -rf "$IMAGES_DIR"; mkdir -p "$IMAGES_DIR/security"
common_dev_args=(--build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "NODE_IMAGE=$NODE_IMAGE" --build-arg "BUILD_DATE=$BUILD_DATE" --build-arg "GIT_COMMIT=$GIT_COMMIT" --build-arg "SANDBOX_VERSION=$VERSION" --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" --build-arg "GEMINI_CLI_VERSION=$GEMINI_CLI_VERSION" --build-arg "TAVILY_CLI_VERSION=$TAVILY_CLI_VERSION" --build-arg "TAVILY_MCP_VERSION=$TAVILY_MCP_VERSION" --build-arg "MCP_REMOTE_VERSION=$MCP_REMOTE_VERSION" --build-arg "SNYK_CLI_VERSION=$SNYK_CLI_VERSION" --build-arg "NPM_REGISTRY=$NPM_REGISTRY" --build-arg "AWSCLI_URL=$AWSCLI_URL" --build-arg "AWSCLI_SHA256=$AWSCLI_SHA256" --build-arg "DATABRICKS_CLI_VERSION=$DATABRICKS_CLI_VERSION" --build-arg "DATABRICKS_CLI_URL=$DATABRICKS_CLI_URL" --build-arg "DATABRICKS_CLI_SHA256=$DATABRICKS_CLI_SHA256" --build-arg "UCODE_GIT_REF=$UCODE_GIT_REF" --build-arg "GCM_VERSION=$GCM_VERSION" --build-arg "GCM_SHA256=$GCM_SHA256")
echo '[1/4] Building devcontainer...'; docker build --no-cache -f "$ROOT/.devcontainer/Dockerfile" --target "$TARGET" "${common_dev_args[@]}" -t sandbox/devcontainer:v1 "$ROOT"
if [[ "${SKIP_CIS_ASSESSMENT:-false}" == true ]]; then
  echo '[2/4] CIS/OpenSCAP assessment SKIPPED for POC fast iteration.' >&2
  cat > "$IMAGES_DIR/security/CIS-ASSESSMENT-SKIPPED.txt" <<EOF
CIS_ASSESSMENT_SKIPPED=true
SANDBOX_VERSION=$VERSION
BUILD_DATE=$BUILD_DATE
REASON=POC fast iteration requested with --skip-cis-assessment
SECURITY_EVIDENCE_VALID=false
EOF
else
  echo '[2/4] Assessing final devcontainer...'
  CIS_REPORT_DIR="$ROOT/security/reports" REQUIRE_CIS_PASS="$REQUIRE_CIS_PASS" bash "$ROOT/scripts/security/assess-cis-l1.sh" sandbox/devcontainer:v1
  cp "$ROOT/security/reports/"* "$IMAGES_DIR/security/"
  cp "$ROOT/security/CIS-TAILORING-README.md" "$IMAGES_DIR/security/"
  [[ -f "$ROOT/security/cis-tailoring.xml" ]] && cp "$ROOT/security/cis-tailoring.xml" "$IMAGES_DIR/security/" || true
fi
echo '[3/4] Building Squid...'; docker build --no-cache -f "$ROOT/squid/Dockerfile" --build-arg "BASE_IMAGE=$SQUID_BASE_IMAGE" --build-arg "BUILD_DATE=$BUILD_DATE" -t sandbox/squid:v1 "$ROOT/squid"
echo '[4/4] Exporting images and integrity metadata...'; docker save sandbox/devcontainer:v1 -o "$IMAGES_DIR/sandbox-devcontainer.tar"; docker save sandbox/squid:v1 -o "$IMAGES_DIR/sandbox-squid.tar"
dev_id="$(docker image inspect sandbox/devcontainer:v1 --format '{{.Id}}')"; squ_id="$(docker image inspect sandbox/squid:v1 --format '{{.Id}}')"
cat > "$IMAGES_DIR/image-manifest.env" <<EOF
SANDBOX_VERSION=$VERSION
DEVCONTAINER_TAG=sandbox/devcontainer:v1
DEVCONTAINER_ID=$dev_id
SQUID_TAG=sandbox/squid:v1
SQUID_ID=$squ_id
EOF
python3 - "$IMAGES_DIR/image-manifest.json" <<PY2
import json,sys
m={"sandboxVersion":"$VERSION","buildDate":"$BUILD_DATE","gitCommit":"$GIT_COMMIT","target":"$TARGET","baseImage":"$BASE_IMAGE","nodeImage":"$NODE_IMAGE","claudeCodeVersion":"$CLAUDE_CODE_VERSION","geminiCliVersion":"$GEMINI_CLI_VERSION","tavilyCliVersion":"$TAVILY_CLI_VERSION","tavilyMcpVersion":"$TAVILY_MCP_VERSION","mcpRemoteVersion":"$MCP_REMOTE_VERSION","snykCliVersion":"$SNYK_CLI_VERSION","databricksCliVersion":"$DATABRICKS_CLI_VERSION","ucodeGitRef":"$UCODE_GIT_REF","cisProfile":"$CIS_PROFILE_ID","ssgVersion":"$SSG_VERSION","images":{"devcontainer":{"tag":"sandbox/devcontainer:v1","id":"$dev_id"},"squid":{"tag":"sandbox/squid:v1","id":"$squ_id"}}}
open(sys.argv[1],'w').write(json.dumps(m,indent=2))
PY2
: > "$IMAGES_DIR/runtime-policy.sha256"; for rel in .devcontainer/devcontainer.json poc/docker-compose.yml; do [[ -s "$ROOT/$rel" ]] || { echo "ERROR: missing $rel" >&2; exit 1; }; printf '%s  %s\n' "$(sha256sum "$ROOT/$rel"|awk '{print $1}')" "$rel" >> "$IMAGES_DIR/runtime-policy.sha256"; done
(cd "$IMAGES_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
echo "[OK] POC two-image bundle created under $IMAGES_DIR"
