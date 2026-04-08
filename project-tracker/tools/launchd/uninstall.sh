#!/bin/bash
# Uninstall Marginalia LaunchAgents. Stops and removes all three services.
#
# Usage: uninstall.sh

set -eu

AGENTS_DIR="$HOME/Library/LaunchAgents"

for svc in api frontend whisper; do
  label="net.hylograph.marginalia.${svc}"
  plist="$AGENTS_DIR/${label}.plist"

  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "  - $label"
  fi
done

echo
echo "Uninstalled. Any manually-started processes are untouched."
