#!/bin/bash
# Watches tasks/receipts/to-local/ in the task checkout and raises one macOS
# notification per receipt that the cloud agent wrote for a round-trip task.
# Read-only: it never fetches, commits, pushes, calls a model or edits the
# checkout. Files arrive through the pull-only sync timer; the protocol is
# tasks/README.md, section "Receipts".
#
#   bash receipt-notify.sh ABSOLUTE_TASK_CHECKOUT
#
# Environment overrides:
#   RELAY_REPO          checkout path, used when no argument is given
#   RELAY_STATE_DIR     seen list directory, default
#                       ~/Library/Application Support/agent-relay
#   RELAY_LOG           log file, default
#                       ~/Library/Logs/agent-relay/receipt-notify.log
#   RELAY_OSASCRIPT_BIN notification binary, default /usr/bin/osascript
set -eu
REPO=${1:-${RELAY_REPO:-}}
[ -n "$REPO" ] || { echo 'usage: bash receipt-notify.sh ABSOLUTE_TASK_CHECKOUT' >&2; exit 1; }
case "$REPO" in /*) ;; *) echo 'Absolute checkout path required' >&2; exit 1;; esac
DIR="$REPO/tasks/receipts/to-local"
STATE_DIR=${RELAY_STATE_DIR:-"$HOME/Library/Application Support/agent-relay"}
SEEN="$STATE_DIR/receipts-seen.txt"
LOG=${RELAY_LOG:-"$HOME/Library/Logs/agent-relay/receipt-notify.log"}
OSASCRIPT=${RELAY_OSASCRIPT_BIN:-/usr/bin/osascript}
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

[ -d "$DIR" ] || { log "receipt directory missing, skipping: $DIR"; exit 0; }

# First run only records what is already there, so a fresh install never
# replays old receipts as new notifications.
first_run=false
[ -f "$SEEN" ] || { first_run=true; : > "$SEEN"; }

# Escape backslashes and double quotes so receipt text cannot inject AppleScript.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

shopt -s nullglob
for f in "$DIR"/*.md; do
  id=$(basename "$f" .md)
  [ "$id" = README ] && continue
  grep -qxF -- "$id" "$SEEN" && continue
  if [ "$first_run" = true ]; then
    printf '%s\n' "$id" >> "$SEEN"
    log "first run, marked existing receipt as seen without notifying: $id"
    continue
  fi
  status=$(sed -n 's/^- Result status:[[:space:]]*//p' "$f" | head -n 1)
  summary=$(sed -n 's/^- Summary:[[:space:]]*//p' "$f" | head -n 1 | cut -c1-120)
  title="Agent Relay receipt: ${status:-unknown}"
  msg="${id}: ${summary:-open the receipt file}"
  if "$OSASCRIPT" -e "display notification \"$(esc "$msg")\" with title \"$(esc "$title")\""; then
    # Mark seen only after a successful notification, so a failure is retried
    # on the next timer tick instead of being lost.
    printf '%s\n' "$id" >> "$SEEN"
    log "notified: $id (${status:-unknown})"
  else
    log "notification failed, retrying next run: $id"
  fi
done
