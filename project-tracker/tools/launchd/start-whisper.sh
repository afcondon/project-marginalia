#!/bin/bash
# Start the Whisper transcription sidecar on :3200, with exponential backoff.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib-backoff.sh"

STATE="$HOME/Library/Logs/marginalia/whisper.failures"
backoff_before_start "$STATE"

export PATH="/Library/Frameworks/Python.framework/Versions/3.13/bin:$PATH"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"
start=$(date +%s)
python3 tools/whisper-server.py
rc=$?
backoff_record_outcome "$STATE" $(($(date +%s) - start))
exit $rc
