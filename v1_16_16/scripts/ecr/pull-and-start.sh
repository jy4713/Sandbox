#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose:
#   Developer Production launcher. Fetches the centrally approved manifest from
#   AWS SSM, validates the two approved ECR image references, pulls exact
#   DevContainer + Squid digests, creates local runtime aliases, and starts
#   Docker Compose.
#
# Logging:
#   Creates host-visible log directories. No Sentinel credential or monitoring
#   sidecar is required by this launcher.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$ROOT/.env"
COMPOSE="$ROOT/docker-compose.yml"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT/.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE. Configure runtime values and rerun. Protect .env if AWS static credentials are used." >&2
  exit 2
fi

get_env() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r'
}

PROFILE="$(get_env SANDBOX_AWS_PROFILE)"; PROFILE="${PROFILE:-sandbox}"
REGION="$(get_env AWS_REGION)"; REGION="${REGION:-eu-west-2}"
SSO_SESSION="$(get_env AWS_SSO_SESSION)"; SSO_SESSION="${SSO_SESSION:-$PROFILE}"
SSO_START_URL="$(get_env AWS_SSO_START_URL)"
SSO_REGION="$(get_env AWS_SSO_REGION)"
SSO_ACCOUNT_ID="$(get_env AWS_SSO_ACCOUNT_ID)"
SSO_ROLE_NAME="$(get_env AWS_SSO_ROLE_NAME)"
ACCESS_KEY="$(get_env AWS_ACCESS_KEY_ID)"
SECRET_KEY="$(get_env AWS_SECRET_ACCESS_KEY)"
SESSION_TOKEN="$(get_env AWS_SESSION_TOKEN)"
PREFIX="$(get_env SSM_PREFIX)"; PREFIX="${PREFIX:-/sandbox}"
REGISTRY="$(get_env ECR_REGISTRY)"
DEVELOPER_ID="$(get_env DEVELOPER_ID)"
MANIFEST_PARAMETER="$(get_env APPROVED_IMAGES_SSM_PARAMETER)"
MANIFEST_PARAMETER="${MANIFEST_PARAMETER:-${PREFIX%/}/runtime/approved-images-json}"

[[ -n "$REGISTRY" && -n "$DEVELOPER_ID" && "$DEVELOPER_ID" != yourname ]] || {
  echo 'ERROR: configure ECR_REGISTRY and DEVELOPER_ID in .env' >&2
  exit 1
}
REGISTRY="${REGISTRY%/}"

LOG_ROOT="$(get_env SANDBOX_LOG_ROOT)"
if [[ -z "$LOG_ROOT" ]]; then
  LOG_ROOT="$ROOT/logs"
elif [[ "$LOG_ROOT" =~ ^[A-Za-z]:[/\\] ]] && command -v cygpath >/dev/null 2>&1; then
  LOG_ROOT="$(cygpath -u "$LOG_ROOT")"
elif [[ "$LOG_ROOT" != /* ]]; then
  LOG_ROOT="$ROOT/$LOG_ROOT"
fi
mkdir -p "$LOG_ROOT/devcontainer" "$LOG_ROOT/squid"
LOG_ROOT="$(cd "$LOG_ROOT" && pwd)"
export SANDBOX_LOG_ROOT="$LOG_ROOT"
echo "Host log root: $LOG_ROOT"

# Authentication priority: static environment credentials first; SSO fallback.
AWS_AUTH_MODE=sso
if [[ -n "$ACCESS_KEY" || -n "$SECRET_KEY" || -n "$SESSION_TOKEN" ]]; then
  [[ -n "$ACCESS_KEY" && -n "$SECRET_KEY" ]] || { echo 'ERROR: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be configured together; partial static credentials do not fall back to SSO.' >&2; exit 1; }
  export AWS_ACCESS_KEY_ID="$ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
  if [[ -n "$SESSION_TOKEN" ]]; then export AWS_SESSION_TOKEN="$SESSION_TOKEN"; else unset AWS_SESSION_TOKEN; fi
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  AWS_AUTH_MODE=static
  echo 'AWS authentication mode: static environment credentials (SSO values are not required).'
else
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  for pair in "AWS_SSO_START_URL:$SSO_START_URL" "AWS_SSO_REGION:$SSO_REGION" "AWS_SSO_ACCOUNT_ID:$SSO_ACCOUNT_ID" "AWS_SSO_ROLE_NAME:$SSO_ROLE_NAME"; do
    key="${pair%%:*}"; val="${pair#*:}"
    [[ -n "$val" && "$val" != *'<'* && "$val" != *'>'* ]] || { echo "ERROR: $key is not configured in .env and no static AWS key pair is present" >&2; exit 1; }
  done
  [[ "$SSO_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo 'ERROR: AWS_SSO_ACCOUNT_ID must be 12 digits' >&2; exit 1; }
  mkdir -p "$HOME/.aws"; chmod 700 "$HOME/.aws"
  touch "$HOME/.aws/config"; chmod 600 "$HOME/.aws/config"
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  awk '/^# BEGIN AI-SANDBOX MANAGED SSO$/{skip=1;next}/^# END AI-SANDBOX MANAGED SSO$/{skip=0;next}!skip{print}' "$HOME/.aws/config" > "$tmp"
  cat >> "$tmp" <<CFG
# BEGIN AI-SANDBOX MANAGED SSO
[sso-session $SSO_SESSION]
sso_start_url = $SSO_START_URL
sso_region = $SSO_REGION
sso_registration_scopes = sso:account:access

[default]
sso_session = $SSO_SESSION
sso_account_id = $SSO_ACCOUNT_ID
sso_role_name = $SSO_ROLE_NAME
region = $REGION
output = json

[profile $PROFILE]
sso_session = $SSO_SESSION
sso_account_id = $SSO_ACCOUNT_ID
sso_role_name = $SSO_ROLE_NAME
region = $REGION
output = json
# END AI-SANDBOX MANAGED SSO
CFG
  mv "$tmp" "$HOME/.aws/config"; chmod 600 "$HOME/.aws/config"; trap - EXIT
fi

aws_cli(){
  if [[ "$AWS_AUTH_MODE" == static ]]; then aws "$@"; else aws --profile "$PROFILE" "$@"; fi
}

if ! aws_cli sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  if [[ "$AWS_AUTH_MODE" == static ]]; then
    echo 'ERROR: static AWS credentials are configured but STS validation failed; SSO fallback is intentionally not attempted.' >&2
    exit 1
  fi
  echo "AWS SSO login required. Open the URL shown below in the host browser." >&2
  aws sso login --profile "$PROFILE" --use-device-code --no-browser
fi
aws_cli sts get-caller-identity --region "$REGION" >/dev/null 2>&1 || { echo 'ERROR: AWS identity validation failed' >&2; exit 1; }

get_ssm() {
  aws_cli ssm get-parameter \
    --name "$1" \
    --region "$REGION" \
    --query Parameter.Value \
    --output text
}

MANIFEST_JSON="$(get_ssm "$MANIFEST_PARAMETER")"
EXPECTED_HASH="$(get_ssm "$MANIFEST_PARAMETER-sha256" | tr '[:upper:]' '[:lower:]')"
ACTUAL_HASH="$(printf '%s' "$MANIFEST_JSON" | sha256sum | awk '{print $1}')"
[[ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]] || {
  echo 'ERROR: approved manifest SHA-256 validation failed' >&2
  exit 1
}

# Parse and validate the exact registry/repository/digest shape before any pull.
eval "$(MANIFEST_JSON="$MANIFEST_JSON" REGISTRY="$REGISTRY" python3 - <<'PY2'
import json, os, re, shlex
manifest = json.loads(os.environ['MANIFEST_JSON'])
registry = os.environ['REGISTRY'].rstrip('/')
if manifest.get('registry') != registry:
    raise SystemExit('ERROR: approved manifest registry mismatch')

def approved(key, repository):
    value = manifest['images'][key]['full']
    pattern = '^' + re.escape(registry) + '/ai-sandbox/' + re.escape(repository) + r'@sha256:[0-9a-f]{64}$'
    if not re.match(pattern, value):
        raise SystemExit('ERROR: invalid approved ' + repository + ' image')
    return value

print('DEV=' + shlex.quote(approved('devcontainer', 'devcontainer')))
print('SQUID=' + shlex.quote(approved('squid', 'squid')))
print('RELEASE=' + shlex.quote(str(manifest.get('releaseTag', 'unknown'))))
PY2
)"

echo "Approved release: $RELEASE"
aws_cli ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

docker pull "$DEV" >/dev/null
docker tag "$DEV" sandbox/approved-devcontainer:current

docker pull "$SQUID" >/dev/null
docker tag "$SQUID" sandbox/approved-squid:current

docker compose --env-file "$ENV_FILE" -f "$COMPOSE" config >/dev/null
docker compose --env-file "$ENV_FILE" -f "$COMPOSE" up -d --force-recreate

echo '[OK] Approved Production sandbox started.'
echo "[OK] Host logs: $LOG_ROOT"
