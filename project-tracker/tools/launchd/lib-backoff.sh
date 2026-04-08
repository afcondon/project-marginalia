#!/bin/bash
# lib-backoff.sh — exponential backoff library for launchd-managed services.
#
# Not a standalone script: sourced by each start-SERVICE.sh. Provides:
#
#   backoff_before_start <state_file>
#       Reads the failure count from state_file and sleeps progressively
#       before returning. First call (failures=0) returns immediately.
#       Backoff: min(600, 5 * 2^failures) seconds.
#
#   backoff_record_outcome <state_file> <lifetime_seconds>
#       Called after the wrapped service exits. If the service ran for
#       at least 60 seconds, reset the failure count; otherwise increment.
#
# Typical usage in a start-SERVICE.sh:
#
#     source "$(dirname "$0")/lib-backoff.sh"
#     STATE="$HOME/Library/Logs/marginalia/api.failures"
#     backoff_before_start "$STATE"
#     start=$(date +%s)
#     node server/run.js
#     rc=$?
#     backoff_record_outcome "$STATE" $(($(date +%s) - start))
#     exit $rc

backoff_before_start() {
  local state_file="$1"
  local failures=0
  if [ -f "$state_file" ]; then
    failures=$(cat "$state_file" 2>/dev/null || echo 0)
  fi
  case "$failures" in
    ''|*[!0-9]*) failures=0 ;;
  esac

  if [ "$failures" -eq 0 ]; then
    return 0
  fi

  local backoff
  backoff=$((5 * (2 ** failures)))
  [ "$backoff" -gt 600 ] && backoff=600
  echo "[backoff] failures=$failures, sleeping ${backoff}s before start" >&2
  sleep "$backoff"
}

backoff_record_outcome() {
  local state_file="$1"
  local lifetime="$2"
  local failures=0
  if [ -f "$state_file" ]; then
    failures=$(cat "$state_file" 2>/dev/null || echo 0)
  fi
  case "$failures" in
    ''|*[!0-9]*) failures=0 ;;
  esac

  if [ "$lifetime" -ge 60 ]; then
    echo "0" > "$state_file"
    echo "[backoff] service ran for ${lifetime}s — reset failure count" >&2
  else
    local new_count=$((failures + 1))
    echo "$new_count" > "$state_file"
    echo "[backoff] service died after ${lifetime}s — failure count now $new_count" >&2
  fi
}
