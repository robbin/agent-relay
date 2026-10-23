#!/bin/bash
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'macOS required' >&2; exit 1; }
LABEL=io.agent-relay.sync
RUNNER_LABEL=io.agent-relay.runner
RECEIPT_LABEL=io.agent-relay.receipt-notify
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNNER_PLIST="$HOME/Library/LaunchAgents/$RUNNER_LABEL.plist"
RECEIPT_PLIST="$HOME/Library/LaunchAgents/$RECEIPT_LABEL.plist"
DEST="$HOME/Library/Application Support/agent-relay"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL"
fi
if launchctl print "gui/$(id -u)/$RUNNER_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$RUNNER_LABEL"
fi
if launchctl print "gui/$(id -u)/$RECEIPT_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$RECEIPT_LABEL"
fi
rm -f "$PLIST" "$RUNNER_PLIST" "$RECEIPT_PLIST" \
  "$DEST/sync.sh" "$DEST/relay-runner.sh" "$DEST/receipt-notify.sh"
if [ -d "$DEST" ]; then rmdir "$DEST" 2>/dev/null || true; fi
echo 'Removed installed timers and scripts. Task repository, logs, runner state (markers, pause file, receipts seen list) and task locks preserved.'
