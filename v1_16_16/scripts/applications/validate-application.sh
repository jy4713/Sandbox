#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'ERROR: Python 3 is required on the Admin source workstation for the v1.16.16 helper.' >&2; exit 1; }
exec python3 "$ROOT/scripts/applications/application-helper.py" validate "$@"
