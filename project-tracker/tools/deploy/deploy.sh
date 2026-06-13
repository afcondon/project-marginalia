#!/usr/bin/env bash
# Marginalia deploy -- run from the MBP. Ships origin/<branch> to the MacMini.
#
#   make deploy                         # preferred entry (from project-tracker/)
#   bash tools/deploy/deploy.sh         # equivalent
#   bash tools/deploy/deploy.sh --check # report the mini's state, change nothing
#
# Deploy ships whatever is on origin/<branch>, NOT your working tree. Workflow:
#
#   1. edit on the MBP
#   2. git commit && git push          (origin/main on GitHub)
#   3. make deploy                      (mini pulls, builds, restarts)
#
# The mini builds host-native artifacts (duckdb binding, spago output/, the
# frontend bundle) from source -- nothing large is shipped over the wire. The
# current remote-deploy.sh is scp'd over each run so the mini never executes a
# stale copy of the deploy logic.
#
# Env overrides: MARGINALIA_DEPLOY_HOST, MARGINALIA_REMOTE_DIR, DEPLOY_BRANCH.

set -euo pipefail

HOST="${MARGINALIA_DEPLOY_HOST:-andrew@andrews-mac-mini}"
REMOTE_DIR="${MARGINALIA_REMOTE_DIR:-/Users/andrew/work/marginalia-demo/project-tracker}"
BRANCH="${DEPLOY_BRANCH:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_info=$'\033[36m'; c_err=$'\033[31m'; c_off=$'\033[0m'
log() { printf '%s[deploy]%s %s\n' "$c_info" "$c_off" "$*"; }
die() { printf '%s[deploy] ERROR:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

GIT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
g() { git -C "$GIT_ROOT" "$@"; }

if [ "$CHECK" = "0" ]; then
  # Guard: don't deploy commits you forgot to push. Deploy ships origin/<branch>.
  g fetch --quiet origin "$BRANCH"
  UNPUSHED="$(g rev-list --count "origin/$BRANCH..$BRANCH" 2>/dev/null || echo '?')"
  [ "$UNPUSHED" = "0" ] || die "$UNPUSHED local commit(s) on $BRANCH not pushed to origin -- run 'git push' first."
  log "origin/$BRANCH = $(g rev-parse --short "origin/$BRANCH") -- shipping to $HOST"
fi

ssh -o ConnectTimeout=10 "$HOST" "test -d '$REMOTE_DIR'" \
  || die "cannot reach $HOST, or $REMOTE_DIR is missing"

log "shipping current deploy logic to the mini..."
scp -q "$SCRIPT_DIR/remote-deploy.sh" "$HOST:/tmp/marginalia-remote-deploy.sh" \
  || die "scp of remote-deploy.sh failed"

REMOTE_ENV="MARGINALIA_DIR='$REMOTE_DIR' DEPLOY_BRANCH='$BRANCH'"
[ "$CHECK" = "1" ] && REMOTE_ENV="$REMOTE_ENV DEPLOY_CHECK=1"

log "running remote deploy on $HOST..."
echo "------------------------------------------------------------"
ssh -o ConnectTimeout=10 "$HOST" "$REMOTE_ENV bash /tmp/marginalia-remote-deploy.sh"
echo "------------------------------------------------------------"
log "done."
