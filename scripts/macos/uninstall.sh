#!/bin/bash
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'macOS required' >&2; exit 1; }
LABEL=io.agent-relay.sync
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="$HOME/Library/Application Support/agent-relay"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$LABEL"
fi
rm -f "$PLIST" "$DEST/sync.sh"
if [ -d "$DEST" ]; then rmdir "$DEST"; fi
echo 'Removed timer and installed script. Task repository and logs preserved.'
