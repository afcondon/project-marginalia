#!/bin/bash
# SDI router LaunchAgent entry point.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
cd "$SCRIPT_DIR/.."
exec node router.mjs
