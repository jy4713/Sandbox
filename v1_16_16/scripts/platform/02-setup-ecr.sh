#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Production build/push of DevContainer + Squid. Logging is host-side.
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; source "$ROOT/scripts/common/load-build-env.sh"
ECR_REGISTRY="${ECR_REGISTRY:?Set ECR_REGISTRY}"; AWS_REGION="${AWS_REGION:-eu-west-2}"; TAG="$RELEASE_TAG"; BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
for repo in ai-sandbox/devcontainer ai-sandbox/squid; do aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1 || aws ecr create-repository --repository-name "$repo" --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true --region "$AWS_REGION" >/dev/null; aws ecr put-image-tag-mutability --repository-name "$repo" --image-tag-mutability IMMUTABLE --region "$AWS_REGION" >/dev/null; aws ecr put-image-scanning-configuration --repository-name "$repo" --image-scanning-configuration scanOnPush=true --region "$AWS_REGION" >/dev/null; done
DEV="$ECR_REGISTRY/ai-sandbox/devcontainer:$TAG"; SQ="$ECR_REGISTRY/ai-sandbox/squid:$TAG"
args=(--build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "NODE_IMAGE=$NODE_IMAGE" --build-arg "BUILD_DATE=$BUILD_DATE" --build-arg "GIT_COMMIT=$GIT_COMMIT" --build-arg "SANDBOX_VERSION=$SANDBOX_VERSION" --build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION" --build-arg "GEMINI_CLI_VERSION=$GEMINI_CLI_VERSION" --build-arg "TAVILY_CLI_VERSION=$TAVILY_CLI_VERSION" --build-arg "TAVILY_MCP_VERSION=$TAVILY_MCP_VERSION" --build-arg "MCP_REMOTE_VERSION=$MCP_REMOTE_VERSION" --build-arg "SNYK_CLI_VERSION=$SNYK_CLI_VERSION" --build-arg "NPM_REGISTRY=$NPM_REGISTRY" --build-arg "AWSCLI_URL=$AWSCLI_URL" --build-arg "AWSCLI_SHA256=$AWSCLI_SHA256" --build-arg "DATABRICKS_CLI_VERSION=$DATABRICKS_CLI_VERSION" --build-arg "DATABRICKS_CLI_URL=$DATABRICKS_CLI_URL" --build-arg "DATABRICKS_CLI_SHA256=$DATABRICKS_CLI_SHA256" --build-arg "UCODE_GIT_REF=$UCODE_GIT_REF" --build-arg "GCM_VERSION=$GCM_VERSION" --build-arg "GCM_SHA256=$GCM_SHA256")
echo '[1/4] Building DevContainer...'; docker build --no-cache -f "$ROOT/.devcontainer/Dockerfile" --target "$DEVCONTAINER_TARGET" "${args[@]}" -t "$DEV" "$ROOT"
echo '[2/4] CIS release gate...'; CIS_REPORT_DIR="$ROOT/security/reports" REQUIRE_CIS_PASS=true bash "$ROOT/scripts/security/assess-cis-l1.sh" "$DEV"
echo '[3/4] Building Squid...'; docker build --no-cache -f "$ROOT/squid/Dockerfile" --build-arg "BASE_IMAGE=$SQUID_BASE_IMAGE" --build-arg "BUILD_DATE=$BUILD_DATE" -t "$SQ" "$ROOT/squid"
echo '[4/4] Push + approved manifest...'; docker push "$DEV" >/dev/null; docker push "$SQ" >/dev/null
digest(){ aws ecr describe-images --repository-name "$1" --image-ids "imageTag=$TAG" --region "$AWS_REGION" --query 'imageDetails[0].imageDigest' --output text; }; DEV_D="$(digest ai-sandbox/devcontainer)"; SQ_D="$(digest ai-sandbox/squid)"
python3 - "$ROOT/ecr/approved-images.json" <<PY2
import json,sys
m={"approvedAt":"$BUILD_DATE","sandboxVersion":"$SANDBOX_VERSION","releaseTag":"$TAG","gitCommit":"$GIT_COMMIT","registry":"$ECR_REGISTRY","cisEvidence":"security/reports/cis-l1-report.html","toolVersions":{"claudeCode":"$CLAUDE_CODE_VERSION","geminiCli":"$GEMINI_CLI_VERSION","tavilyCli":"$TAVILY_CLI_VERSION","tavilyMcp":"$TAVILY_MCP_VERSION","mcpRemote":"$MCP_REMOTE_VERSION","snykCli":"$SNYK_CLI_VERSION","databricksCli":"$DATABRICKS_CLI_VERSION","ucodeGitRef":"$UCODE_GIT_REF"},"images":{"devcontainer":{"full":"$ECR_REGISTRY/ai-sandbox/devcontainer@$DEV_D","digest":"$DEV_D"},"squid":{"full":"$ECR_REGISTRY/ai-sandbox/squid@$SQ_D","digest":"$SQ_D"}}}
open(sys.argv[1],'w').write(json.dumps(m,separators=(',',':')))
PY2
PUBLISH="${PUBLISH_APPROVED_MANIFEST_TO_SSM:-true}"; if [[ "$PUBLISH" != false ]]; then PREFIX="${SSM_PREFIX:-/sandbox}"; PARAM="${APPROVED_IMAGES_SSM_PARAMETER:-${PREFIX%/}/runtime/approved-images-json}"; JSON="$(cat "$ROOT/ecr/approved-images.json")"; HASH="$(printf '%s' "$JSON"|sha256sum|awk '{print $1}')"; aws ssm put-parameter --name "$PARAM" --type String --value "$JSON" --overwrite --region "$AWS_REGION" >/dev/null; aws ssm put-parameter --name "$PARAM-sha256" --type String --value "$HASH" --overwrite --region "$AWS_REGION" >/dev/null; fi
echo '[OK] Production two-image release complete.'
