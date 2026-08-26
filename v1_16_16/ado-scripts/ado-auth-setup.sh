#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Shows and validates the supported Azure DevOps authentication model inside the devcontainer.
# Admin maintenance: Update when ADO authentication modes, SSM parameter names, or Git credential flow change.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# ado-auth-setup — ADO authentication status and guidance
#
# Security model:
#   Earlier versions stored the ADO PAT in ~/.git-credentials-ado via
#   `git config credential.helper store`. That wrote a long-lived secret to
#   disk where any process in the container — including code run by an AI
#   agent — could read it.
#
#   The current package removes disk storage entirely. The PAT is fetched from SSM per
#   command and supplied to git through GIT_ASKPASS, so it exists only in
#   that one process's memory.
#
# Usage:
#   ado-auth-setup check     Show current auth configuration and test access
#   ado-auth-setup help      Show how to run git commands with credentials
# =============================================================================
set -uo pipefail

mode="${1:-check}"

show_help() {
    cat <<'HELP'
ADO authentication — current Sandbox model

There is no separate login step. Wrap each git or ADO command:

    run-with-ssm-secrets --profile ado -- git clone https://dev.azure.com/ORG/PROJECT/_git/REPO
    run-with-ssm-secrets --profile ado -- git fetch
    run-with-ssm-secrets --profile ado -- git pull
    run-with-ssm-secrets --profile ado -- git push origin feature/ai-123
    run-with-ssm-secrets --profile ado -- ado-pr-create --title "..." --source feature/ai-123
    run-with-ssm-secrets --profile ado -- ado-trigger --pipeline-id 42 --wait

Why every command needs the wrapper:
  The PAT lives only inside the wrapped process. A bare `git push` has no
  credentials and will fail — that is the intended behaviour. It means an
  AI agent cannot push using credentials it was never given.

Commands that need no credentials:
    git status / git diff / git log / git commit / git checkout -b
    git clone of a public repository
HELP
}

show_check() {
    echo "=== ADO authentication status ==="
    echo

    echo "Model: per-command SSM injection"
    echo "  PAT source     : AWS SSM ${SSM_PREFIX:-/sandbox}/ado-pat"
    echo "  Delivery       : GIT_ASKPASS, memory only"
    echo "  Disk storage   : none"
    echo

    echo "-- Configuration --"
    helper="$(git config --global credential.helper 2>/dev/null || true)"
    if [[ -z "$helper" ]]; then
        echo "  [OK]   credential.helper not set (expected)"
    else
        echo "  [WARN] credential.helper is set: $helper"
        echo "         The Sandbox does not use a persistent credential helper. If this points at"
        echo "         a store file, remove it:"
        echo "           git config --global --unset credential.helper"
    fi

    for stale in "$HOME/.git-credentials" "$HOME/.git-credentials-ado"; do
        if [[ -f "$stale" ]]; then
            echo "  [FAIL] stale credential file on disk: $stale"
            echo "         Remove it: shred -u '$stale' 2>/dev/null || rm -f '$stale'"
        fi
    done
    [[ -f "$HOME/.git-credentials" || -f "$HOME/.git-credentials-ado" ]] \
        || echo "  [OK]   no credential files on disk"

    if [[ -x /usr/local/bin/git-askpass-ado ]]; then
        echo "  [OK]   git-askpass-ado is installed"
    else
        echo "  [FAIL] git-askpass-ado is missing — rebuild the image"
    fi

    echo
    echo "-- Current process --"
    if [[ -n "${ADO_PAT:-}" ]]; then
        echo "  ADO_PAT     : present (${#ADO_PAT} chars) — you are inside a wrapped command"
        echo "  ADO_ORG     : ${ADO_ORG:-not set}"
        echo "  ADO_PROJECT : ${ADO_PROJECT:-not set}"
        echo "  ADO_REPO    : ${ADO_REPO:-not set}"
    else
        echo "  ADO_PAT     : not present (expected in a plain shell)"
        echo
        echo "  To test connectivity:"
        echo "    run-with-ssm-secrets --profile ado -- ado-auth-setup check"
    fi

    echo
    echo "-- Connectivity --"
    if [[ -n "${ADO_PAT:-}" && -n "${ADO_ORG:-}" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -u ":${ADO_PAT}" \
            "https://dev.azure.com/${ADO_ORG}/_apis/projects?api-version=7.0" 2>/dev/null || echo 000)
        case "$code" in
            200) echo "  [OK]   authenticated to dev.azure.com/${ADO_ORG}" ;;
            401|203) echo "  [FAIL] PAT rejected (expired or wrong scope)" ;;
            407) echo "  [FAIL] blocked by Squid — check whitelist for dev.azure.com" ;;
            000) echo "  [FAIL] no response — check network and Squid" ;;
            *)   echo "  [WARN] unexpected HTTP $code" ;;
        esac
    else
        echo "  [SKIP] no PAT in this process"
    fi
}

case "$mode" in
    check) show_check ;;
    help|-h|--help) show_help ;;
    *)
        echo "ERROR: unknown mode '$mode'" >&2
        echo "Usage: ado-auth-setup [check|help]" >&2
        exit 2
        ;;
esac
