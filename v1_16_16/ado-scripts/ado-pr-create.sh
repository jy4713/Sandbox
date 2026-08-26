#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Bash workflow for creating Azure DevOps pull requests using approved authentication.
# Admin maintenance: Update only for ADO API/workflow changes; keep the PowerShell peer behaviorally equivalent.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# ado-pr-create — Create a Pull Request in Azure DevOps via REST API
#
# Enforces sandbox policy: AI agent changes MUST go via PR, never direct push
# to main/master. This script wraps the ADO REST API for PR creation.
#
# Usage:
#   bash ado-pr-create.sh --title "feat: add X" --source feature/my-branch
#
# Options:
#   --title         PR title (required)
#   --source        Source branch (required; e.g. feature/ai-agent-change)
#   --target        Target branch (default: main)
#   --description   PR description
#   --reviewers     Comma-separated ADO user UPNs (e.g. user@org.com,user2@org.com)
#   --draft         Create as draft PR
#   --auto-complete Set auto-complete (merges when all checks pass)
#   --org           ADO org (or set ADO_ORG)
#   --project       ADO project (or set ADO_PROJECT)
#   --repo          Repository name (or set ADO_REPO)
# =============================================================================
set -euo pipefail

TITLE=""; SOURCE=""; TARGET="main"; DESCRIPTION=""; REVIEWERS=""; DRAFT=false; AUTO_COMPLETE=false
ORG="${ADO_ORG:-}"; PROJECT="${ADO_PROJECT:-}"; REPO="${ADO_REPO:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)         TITLE="$2";       shift 2 ;;
    --source)        SOURCE="$2";      shift 2 ;;
    --target)        TARGET="$2";      shift 2 ;;
    --description)   DESCRIPTION="$2"; shift 2 ;;
    --reviewers)     REVIEWERS="$2";   shift 2 ;;
    --draft)         DRAFT=true;       shift   ;;
    --auto-complete) AUTO_COMPLETE=true; shift  ;;
    --org)           ORG="$2";         shift 2 ;;
    --project)       PROJECT="$2";     shift 2 ;;
    --repo)          REPO="$2";        shift 2 ;;
    *) echo "[ERROR] Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$TITLE" ]]   && { echo "[ERROR] --title required"; exit 1; }
[[ -z "$SOURCE" ]]  && { echo "[ERROR] --source required"; exit 1; }
[[ -z "$ORG" ]]     && { echo "[ERROR] --org or ADO_ORG required"; exit 1; }
[[ -z "$PROJECT" ]] && { echo "[ERROR] --project or ADO_PROJECT required"; exit 1; }
[[ -z "$REPO" ]]    && { echo "[ERROR] --repo or ADO_REPO required"; exit 1; }

# ── Guard: warn if source branch is main/master ───────────────────────────────
if [[ "$SOURCE" == "main" || "$SOURCE" == "master" ]]; then
  echo "[ERROR] Cannot create PR from main/master as source branch."
  echo "        Create a feature branch first: git checkout -b feature/my-change"
  exit 1
fi

# ── Auth header ───────────────────────────────────────────────────────────────
if [[ "${ADO_AUTH:-pat}" == "az" ]]; then
  TOK=$(az account get-access-token \
    --resource "499b84ac-1321-427f-aa17-267ca6975798" \
    --query accessToken -o tsv)
  AUTH_HEADER="Authorization: Bearer ${TOK}"
else
  [[ -z "${ADO_PAT:-}" ]] && { echo "[ERROR] ADO_PAT not set"; exit 1; }
  ENC=$(printf '%s' ":${ADO_PAT}" | base64 -w 0)
  AUTH_HEADER="Authorization: Basic ${ENC}"
fi

BASE="https://dev.azure.com/${ORG}/${PROJECT}/_apis"

# ── Build reviewers array ─────────────────────────────────────────────────────
REVIEWER_JSON="[]"
if [[ -n "$REVIEWERS" ]]; then
  # Look up each reviewer's descriptor ID from their UPN
  REVIEWER_JSON="["
  IFS=',' read -ra UPN_LIST <<< "$REVIEWERS"
  FIRST=true
  for upn in "${UPN_LIST[@]}"; do
    upn="$(echo "$upn" | xargs)"
    DESC=$(curl -s \
      "https://vssps.dev.azure.com/${ORG}/_apis/identities?searchFilter=MailAddress&filterValue=${upn}&api-version=7.1" \
      -H "$AUTH_HEADER" | jq -r '.value[0].id // empty')
    if [[ -n "$DESC" ]]; then
      [[ "$FIRST" == "false" ]] && REVIEWER_JSON+=","
      REVIEWER_JSON+="{\"id\":\"${DESC}\"}"
      FIRST=false
    else
      echo "[WARN] Could not resolve reviewer: $upn"
    fi
  done
  REVIEWER_JSON+="]"
fi

# ── Create PR ─────────────────────────────────────────────────────────────────
BODY=$(jq -n \
  --arg title        "$TITLE" \
  --arg description  "$DESCRIPTION" \
  --arg source       "refs/heads/$SOURCE" \
  --arg target       "refs/heads/$TARGET" \
  --argjson draft    "$DRAFT" \
  --argjson reviewers "$REVIEWER_JSON" \
  '{
    title:              $title,
    description:        $description,
    sourceRefName:      $source,
    targetRefName:      $target,
    isDraft:            $draft,
    reviewers:          $reviewers
  }')

echo "[ado-pr-create] Creating PR: '$TITLE'"
echo "  ${SOURCE} → ${TARGET}  (draft: $DRAFT)"

RESPONSE=$(curl -s -X POST \
  "${BASE}/git/repositories/${REPO}/pullrequests?api-version=7.1" \
  -H "Content-Type: application/json" \
  -H "$AUTH_HEADER" \
  -d "$BODY")

PR_ID=$(echo "$RESPONSE"  | jq -r '.pullRequestId // empty')
PR_URL=$(echo "$RESPONSE" | jq -r '._links.web.href // empty')

if [[ -z "$PR_ID" ]]; then
  echo "[ERROR] PR creation failed:"
  echo "$RESPONSE" | jq .
  exit 1
fi

echo
echo "[OK] PR created:"
echo "  PR ID: $PR_ID"
echo "  URL:   $PR_URL"

# ── Set auto-complete ─────────────────────────────────────────────────────────
if [[ "$AUTO_COMPLETE" == "true" ]]; then
  SELF_ID=$(curl -s \
    "https://vssps.dev.azure.com/${ORG}/_apis/profile/profiles/me?api-version=7.1" \
    -H "$AUTH_HEADER" | jq -r '.id')
  curl -s -X PATCH \
    "${BASE}/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -d "{\"autoCompleteSetBy\":{\"id\":\"${SELF_ID}\"},\"completionOptions\":{\"deleteSourceBranch\":true,\"mergeStrategy\":\"squash\"}}" \
    > /dev/null
  echo "  Auto-complete: enabled (squash merge, delete source branch)"
fi
