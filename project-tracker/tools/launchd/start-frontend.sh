#!/bin/bash
# Start the Marginalia frontend (http-server on :3101), with exponential backoff.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib-backoff.sh"

STATE="$HOME/Library/Logs/marginalia/frontend.failures"
backoff_before_start "$STATE"

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"
start=$(date +%s)
npx http-server frontend/public -p 3101 -c-1 --cors
rc=$?
backoff_record_outcome "$STATE" $(($(date +%s) - start))
exit $rc
