#!/bin/bash
# Install Marginalia LaunchAgents so the API, frontend, and whisper sidecar
# start automatically at login and restart on crash (with exponential backoff
# via the supervisor wrapper).
#
# Usage:
#   install.sh                # install api + frontend (recommended default)
#   install.sh --with-whisper # also install whisper sidecar
#   install.sh --all          # same as --with-whisper
#
# After install, each service is managed individually:
#   launchctl list | grep marginalia
#   launchctl unload ~/Library/LaunchAgents/net.hylograph.marginalia.api.plist
#   launchctl load   ~/Library/LaunchAgents/net.hylograph.marginalia.api.plist
#
# Logs land under ~/Library/Logs/marginalia/

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LOGS_DIR="$HOME/Library/Logs/marginalia"

WITH_WHISPER=0
for arg in "$@"; do
  case "$arg" in
    --with-whisper|--all) WITH_WHISPER=1 ;;
    -h|--help)
      head -20 "$0" | tail -n +2 | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

SERVICES=("api" "frontend")
if [ "$WITH_WHISPER" -eq 1 ]; then
  SERVICES+=("whisper")
fi

mkdir -p "$AGENTS_DIR"
mkdir -p "$LOGS_DIR"

for svc in "${SERVICES[@]}"; do
  label="net.hylograph.marginalia.${svc}"
  plist_src="$SCRIPT_DIR/${label}.plist"
  plist_dst="$AGENTS_DIR/${label}.plist"

  if [ ! -f "$plist_src" ]; then
    echo "  ERROR: plist not found: $plist_src" >&2
    exit 1
  fi

  # Unload if already loaded (ignore errors — it might not be loaded)
  launchctl unload "$plist_dst" 2>/dev/null || true

  # Copy the plist
  cp "$plist_src" "$plist_dst"

  # Reset any stale backoff state so a fresh install starts immediately
  rm -f "$LOGS_DIR/${svc}.failures"

  # Load the agent
  launchctl load "$plist_dst"

  echo "  + $label"
done

echo
echo "Installed. Check status with:"
echo "  launchctl list | grep marginalia"
echo "Logs:"
echo "  $LOGS_DIR/"
