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

cd /Users/afc/work/afc-work/agent-teams/project-tracker
start=$(date +%s)
node server/run.js
rc=$?
backoff_record_outcome "$STATE" $(($(date +%s) - start))
exit $rc
