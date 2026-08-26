#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Admin bootstrap for AWS SSM Parameter Store names used by Sandbox applications. Host-side Sentinel forwarding credentials/configuration are managed separately.
# Admin maintenance: Add/remove parameter names here whenever an application gains or loses runtime secrets. Never embed real secret values in the script or repository.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# Populate all runtime credentials in AWS SSM Parameter Store.
# Run by the platform/admin team once per environment.
# =============================================================================
set -euo pipefail
PREFIX="${SSM_PREFIX:-/sandbox}"; REGION="${AWS_REGION:-eu-west-2}"; KMS="${SSM_KMS_KEY_ID:-alias/aws/ssm}"
echo "=== SSM Parameter Setup === prefix=$PREFIX region=$REGION"
put_s(){ aws ssm put-parameter --name "${PREFIX}/$1" --description "$2" --value "$3" --type SecureString --key-id "$KMS" --overwrite --region "$REGION" --output text --query Version | xargs -I{} echo "  [OK] $1 (v{})"; }
put_p(){ aws ssm put-parameter --name "${PREFIX}/$1" --description "$2" --value "$3" --type String --overwrite --region "$REGION" --output text --query Version | xargs -I{} echo "  [OK] $1 (v{})"; }

echo; echo '--- Direct AI provider credentials ---'
read -rsp '  Anthropic Claude API key: ' V; echo; put_s claude-api-key 'Anthropic Claude API key for direct Claude Code access' "$V"; unset V
read -rsp '  Google Gemini API key: ' V; echo; put_s gemini-api-key 'Google Gemini API key for direct Gemini CLI access' "$V"; unset V

echo; echo '--- Databricks (used by ucode and Databricks CLI) ---'; read -rsp '  Databricks PAT: ' V; echo; put_s databricks-token 'Databricks Personal Access Token' "$V"; unset V
echo; echo '--- Databricks SQL MCP (separate SSM path; same PAT value is acceptable for POC) ---'; read -rsp '  Databricks SQL MCP PAT: ' V; echo; put_s databricks-sql-mcp-token 'Databricks PAT dedicated to managed SQL MCP' "$V"; unset V

echo; echo '--- Azure DevOps (approved SSM-backed mode: PAT) ---'
read -rp '  ADO organisation name: ' O
read -rp '  ADO project name: ' P
read -rp '  ADO repository name: ' R
put_p ado-org 'ADO organisation' "$O"
put_p ado-project 'ADO project' "$P"
put_p ado-repo 'ADO default repository' "$R"
read -rsp '  ADO PAT: ' V; echo
put_s ado-pat 'ADO Personal Access Token' "$V"
unset V

# -----------------------------------------------------------------------------
# APPLICATION MAINTENANCE ZONE - APPLICATION SECRETS
# Add/remove application-specific SSM parameters in this section. Use SecureString
# for credentials and keep the same parameter names in run-with-ssm-secrets.sh.
# Mirror every change in 01-setup-ssm.ps1.
# -----------------------------------------------------------------------------
echo; echo '--- Tavily ---'; read -rsp '  Tavily API key: ' V; echo; put_s tavily-api-key 'Tavily API key' "$V"; unset V
echo; echo '--- Snyk ---'; read -rsp '  Snyk token: ' V; echo; put_s snyk-token 'Snyk API token' "$V"; unset V
echo; echo '--- HiddenLayer ---'; echo '  Enter the tenant/client credentials supplied by your HiddenLayer deployment.'; read -rsp '  HiddenLayer client ID: ' I; echo; read -rsp '  HiddenLayer client secret: ' V; echo; put_s hiddenlayer-client-id 'HiddenLayer client ID' "$I"; put_s hiddenlayer-client-secret 'HiddenLayer client secret' "$V"; unset I V


echo; echo '--- Registered parameters ---'; aws ssm get-parameters-by-path --path "$PREFIX" --region "$REGION" --query 'Parameters[*].{Name:Name,Type:Type}' --output table
echo; echo '[OK] SSM setup complete.'
