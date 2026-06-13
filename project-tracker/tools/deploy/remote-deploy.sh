#!/usr/bin/env bash
# Marginalia remote deploy -- runs ON andrews-mac-mini.
#
# Reconciles the checkout to origin/<branch>, rebuilds the host-local build
# artifacts (node_modules incl. duckdb native binding, server output/, frontend
# bundle.js), restarts the api + frontend LaunchAgents, and health-checks.
# Idempotent. Untracked host files (.env, output.bak*, etc.) are never touched.
#
# Invoked by tools/deploy/deploy.sh from the MBP, which scp's the latest copy
# of THIS script to the mini before running it -- so the deploy logic is never
# stale even when the checkout itself is behind origin.
#
# Env:
#   MARGINALIA_DIR   project-tracker dir (default below)
#   DEPLOY_BRANCH    branch to deploy (default main)
#   DEPLOY_CHECK=1   report state and exit WITHOUT changing anything
#
# Safety model: a whole-tree `git reset --hard origin/<branch>` is used only
# when the tree is dirty/non-fast-forward AND has zero local commits ahead of
# origin (nothing unique to lose). A pre-reset diff is saved to /tmp first.

set -euo pipefail

MARGINALIA_DIR="${MARGINALIA_DIR:-/Users/andrew/work/marginalia-demo/project-tracker}"
BRANCH="${DEPLOY_BRANCH:-main}"

c_info=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_off=$'\033[0m'
log()  { printf '%s[deploy]%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s[deploy]%s %s\n' "$c_ok"   "$c_off" "$*"; }
warn() { printf '%s[deploy]%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s[deploy] ERROR:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

# Resolve node/npm/spago via nvm (login-shell PATH isn't present over ssh).
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
command -v node >/dev/null || die "node not on PATH (nvm load failed)"

[ -d "$MARGINALIA_DIR" ] || die "no directory at $MARGINALIA_DIR"
GIT_ROOT="$(git -C "$MARGINALIA_DIR" rev-parse --show-toplevel)" || die "not a git repo: $MARGINALIA_DIR"
g() { git -C "$GIT_ROOT" "$@"; }
g remote get-url origin | grep -q project-marginalia || die "origin is not project-marginalia -- refusing to touch this checkout"

log "repo:   $GIT_ROOT"
log "subdir: $MARGINALIA_DIR"
g fetch --quiet origin "$BRANCH" || die "git fetch failed"

LOCAL="$(g rev-parse HEAD)"
REMOTE="$(g rev-parse "origin/$BRANCH")"
AHEAD="$(g rev-list --count "origin/$BRANCH..HEAD")"
BEHIND="$(g rev-list --count "HEAD..origin/$BRANCH")"
DIRTY=no; { g diff --quiet && g diff --cached --quiet; } || DIRTY=yes

log "local=$(g rev-parse --short HEAD)  remote=$(g rev-parse --short "origin/$BRANCH")  ahead=$AHEAD  behind=$BEHIND  dirty=$DIRTY"

if [ "${DEPLOY_CHECK:-0}" = "1" ]; then
  ok "check-only -- no changes made"
  exit 0
fi

[ "$AHEAD" = "0" ] || die "checkout has $AHEAD local commit(s) ahead of origin/$BRANCH -- refusing to auto-reconcile. Inspect and resolve by hand."

# --- Reconcile working tree to origin/<branch> -----------------------------
if [ "$LOCAL" = "$REMOTE" ] && [ "$DIRTY" = "no" ]; then
  ok "already at origin/$BRANCH, clean -- no reconcile needed"
elif [ "$DIRTY" = "no" ]; then
  log "clean fast-forward -> origin/$BRANCH"
  g merge --ff-only "origin/$BRANCH" || die "ff-only merge failed unexpectedly"
else
  TS="$(date +%Y%m%d-%H%M%S)"
  BAK="/tmp/marginalia-predeploy-$TS.patch"
  g diff "origin/$BRANCH" > "$BAK" 2>/dev/null || true
  warn "dirty/non-fast-forward tree, 0 commits ahead -> reset --hard origin/$BRANCH"
  warn "  pre-reset diff vs origin/$BRANCH saved to $BAK"
  g reset --hard "origin/$BRANCH" || die "reset --hard failed"
fi

# .env is untracked -> reset never removes it. Assert it survived.
if [ -f "$MARGINALIA_DIR/.env" ]; then ok ".env preserved (untracked)"; else warn "no .env present -- check host config"; fi

# --- Build host-local artifacts --------------------------------------------
cd "$MARGINALIA_DIR"
log "npm install (host-local node_modules incl. duckdb native binding)..."
npm install --no-audit --no-fund --silent || die "npm install failed"
log "building server (spago -> output/)..."
npm run build:server || die "server build failed -- services left running on previous output/"
log "bundling frontend (-> frontend/public/bundle.js)..."
npm run bundle:frontend || die "frontend bundle failed -- services left running on previous bundle"

# --- Restart + health-check ------------------------------------------------
# Static files (bundle.js, styles.css) are served from disk live, so the
# frontend would pick them up without a restart; we restart anyway to also
# cover frontend-server.mjs changes. The api MUST restart to load new output/.
UID_NUM="$(id -u)"
restart_agent() {
  local label="$1"
  if launchctl kickstart -k "gui/$UID_NUM/$label" 2>/dev/null; then
    log "  kickstarted $label"
  else
    warn "  kickstart returned nonzero for $label -- verifying via health check"
  fi
}
healthy() { # url -- poll up to ~60s (covers launchd backoff)
  local url="$1" i
  for i in $(seq 1 30); do
    curl -fsS --max-time 3 "$url" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

log "restarting api..."
restart_agent net.hylograph.marginalia.api
healthy "http://localhost:3100/api/projects" || die "api :3100 unhealthy after restart (see ~/Library/Logs/marginalia/api.log)"
ok "api :3100 healthy"

log "restarting frontend..."
restart_agent net.hylograph.marginalia.frontend
healthy "http://localhost:3101/" || die "frontend :3101 unhealthy after restart (see ~/Library/Logs/marginalia/frontend.log)"
ok "frontend :3101 healthy"

# whisper (:3200) is a separate Python service with its own venv -- not part of
# this build pipeline, so it is intentionally left running untouched.

ok "deploy complete -- now at $(g rev-parse --short "origin/$BRANCH") ($(g log -1 --pretty=%s origin/$BRANCH))"
