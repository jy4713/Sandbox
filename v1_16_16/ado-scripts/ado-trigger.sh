#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Bash workflow for triggering approved Azure DevOps pipeline operations.
# Admin maintenance: Update only for ADO API/workflow changes; keep the PowerShell peer behaviorally equivalent.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# ado-trigger — AI Sandbox ADO Pipeline Trigger Helper
#
# Triggers an Azure DevOps pipeline via REST API and optionally tails the run.
# Authentication: PAT (env ADO_PAT) or Azure CLI token (env ADO_AUTH=az).
#
# Usage:
#   ado-trigger --org <org> --project <project> --pipeline-id <id> [options]
#
# Options:
#   --org          ADO organisation name (e.g. myorg)
#   --project      ADO project name
#   --pipeline-id  Pipeline definition ID (integer)
#   --branch       Source branch (default: main)
#   --params       JSON string of template parameters, e.g. '{"env":"staging"}'
#   --wait         Wait for the run to complete and exit with its status
#   --auth         pat (default) or az (existing approved Azure CLI session)
#
# Environment variables:
#   ADO_PAT        Personal Access Token (when --auth=pat)
#                  Required scopes: Build (read and execute)
#   ADO_ORG        Default org (overridden by --org)
#   ADO_PROJECT    Default project (overridden by --project)
#
# Examples:
#   # Trigger and return immediately
#   ADO_PAT=xxx ado-trigger --org myorg --project MyProj --pipeline-id 42
#
#   # Trigger with params and wait for result
#   ADO_PAT=xxx ado-trigger --org myorg --project MyProj --pipeline-id 42 \
#     --branch feature/my-branch --params '{"deploy_env":"dev"}' --wait
#
#   # Azure CLI bearer-token auth (Azure CLI must already be logged in)
#   ado-trigger --auth az --org myorg --project MyProj --pipeline-id 42 --wait
# =============================================================================
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
ORG="${ADO_ORG:-}"
PROJECT="${ADO_PROJECT:-}"
PIPELINE_ID=""
BRANCH="main"
PARAMS="{}"
WAIT=false
AUTH="pat"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)          ORG="$2";         shift 2 ;;
    --project)      PROJECT="$2";     shift 2 ;;
    --pipeline-id)  PIPELINE_ID="$2"; shift 2 ;;
    --branch)       BRANCH="$2";      shift 2 ;;
    --params)       PARAMS="$2";      shift 2 ;;
    --wait)         WAIT=true;        shift   ;;
    --auth)         AUTH="$2";        shift 2 ;;
    -h|--help)
      sed -n '3,40p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) echo "[ERROR] Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[[ -z "$ORG" ]]         && { echo "[ERROR] --org is required (or set ADO_ORG)"; exit 1; }
[[ -z "$PROJECT" ]]     && { echo "[ERROR] --project is required (or set ADO_PROJECT)"; exit 1; }
[[ -z "$PIPELINE_ID" ]] && { echo "[ERROR] --pipeline-id is required"; exit 1; }

# ── Auth token ────────────────────────────────────────────────────────────────
get_token() {
  if [[ "$AUTH" == "az" ]]; then
    # Azure CLI session: obtain an ADO bearer token
    az account get-access-token \
      --resource "499b84ac-1321-427f-aa17-267ca6975798" \
      --query accessToken -o tsv
  else
    # PAT: base64-encode as Basic auth
    if [[ -z "${ADO_PAT:-}" ]]; then
      echo "[ERROR] ADO_PAT environment variable not set" >&2
      exit 1
    fi
    echo "pat:${ADO_PAT}" | base64 -w 0
    echo "__PAT__"   # marker for header construction below
  fi
}

BASE_URL="https://dev.azure.com/${ORG}/${PROJECT}/_apis"
API_VERSION="api-version=7.1"

build_auth_header() {
  if [[ "$AUTH" == "az" ]]; then
    local tok
    tok=$(az account get-access-token \
      --resource "499b84ac-1321-427f-aa17-267ca6975798" \
      --query accessToken -o tsv)
    echo "Authorization: Bearer ${tok}"
  else
    [[ -z "${ADO_PAT:-}" ]] && { echo "[ERROR] ADO_PAT not set" >&2; exit 1; }
    local encoded
    encoded=$(printf '%s' ":${ADO_PAT}" | base64 -w 0)
    echo "Authorization: Basic ${encoded}"
  fi
}

# ── Trigger pipeline ──────────────────────────────────────────────────────────
echo "[ado-trigger] Triggering pipeline ${PIPELINE_ID} on branch '${BRANCH}'..."
AUTH_HEADER=$(build_auth_header)

BODY=$(jq -n \
  --argjson params "$PARAMS" \
  --arg branch "refs/heads/$BRANCH" \
  '{
    resources: { repositories: { self: { refName: $branch } } },
    templateParameters: $params
  }')

RESPONSE=$(curl -s -X POST \
  "${BASE_URL}/pipelines/${PIPELINE_ID}/runs?${API_VERSION}" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d "$BODY")

RUN_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
RUN_URL=$(echo "$RESPONSE" | jq -r '._links.web.href // empty')
STATE=$(echo "$RESPONSE"   | jq -r '.state // empty')

if [[ -z "$RUN_ID" ]]; then
  echo "[ERROR] Pipeline trigger failed. Response:"
  echo "$RESPONSE" | jq .
  exit 1
fi

echo "[ado-trigger] Run created:"
echo "  Run ID:  $RUN_ID"
echo "  State:   $STATE"
echo "  URL:     $RUN_URL"

# ── Wait for completion ───────────────────────────────────────────────────────
if [[ "$WAIT" == "true" ]]; then
  echo
  echo "[ado-trigger] Waiting for run ${RUN_ID} to complete..."
  POLL_INTERVAL=15
  TIMEOUT=1800   # 30 minutes
  ELAPSED=0

  while true; do
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    AUTH_HEADER=$(build_auth_header)
    STATUS=$(curl -s \
      "${BASE_URL}/pipelines/${PIPELINE_ID}/runs/${RUN_ID}?${API_VERSION}" \
      -H "$AUTH_HEADER")

    STATE=$(echo "$STATUS"  | jq -r '.state')
    RESULT=$(echo "$STATUS" | jq -r '.result // "unknown"')

    echo "  [${ELAPSED}s] state=${STATE} result=${RESULT}"

    if [[ "$STATE" == "completed" ]]; then
      echo
      echo "[ado-trigger] Run completed: $RESULT"
      echo "  URL: $RUN_URL"
      [[ "$RESULT" == "succeeded" ]] && exit 0 || exit 1
    fi

    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      echo "[ERROR] Timeout after ${TIMEOUT}s — run still in state: $STATE"
      exit 1
    fi
  done
fi
