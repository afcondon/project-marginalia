#!/bin/bash
# Start the Marginalia API server, wrapped with exponential backoff.
# Entry point for launchd — point net.hylograph.marginalia.api.plist at this.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib-backoff.sh"

STATE="$HOME/Library/Logs/marginalia/api.failures"
backoff_before_start "$STATE"

# Source nvm so `node` is available
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Project root is two levels up from this script (tools/launchd/ -> project).
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# Optional per-clone .env file — used for MARGINALIA_ATTACHMENT_STORE and
# future config. The MBP install works fine with no .env (defaults preserve
# existing behaviour); a fresh clone on another Mac can set paths here.
if [ -f "$PROJECT_ROOT/.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$PROJECT_ROOT/.env"; set +a
fi

start=$(date +%s)
node server/run.js
rc=$?
backoff_record_outcome "$STATE" $(($(date +%s) - start))
exit $rc
