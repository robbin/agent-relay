#!/bin/bash
# Installs one user launchd job. Never modifies the task repository.
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'macOS required' >&2; exit 1; }
[ "$#" = 1 ] || { echo 'usage: bash install.sh ABSOLUTE_CHECKOUT' >&2; exit 1; }
REPO=$1
case "$REPO" in /*) ;; *) echo 'Absolute checkout path required' >&2; exit 1;; esac
REPO=$(cd "$REPO" && pwd -P)
[ "$(git -C "$REPO" rev-parse --show-toplevel)" = "$REPO" ]
ORIGIN=$(git -C "$REPO" remote get-url origin)
# Never persist credential-bearing URLs in a plist.
case "$ORIGIN" in
  https://github.com/*)
    REST=${ORIGIN#https://github.com/}
    case "$REST" in *[@?:\#]*|*' '*) echo 'Use a credential-free GitHub origin' >&2; exit 1;; esac ;;
  git@github.com:*) ;;
  *) echo 'Installer supports credential-free GitHub HTTPS or SSH origins only' >&2; exit 1;;
esac
LABEL=io.agent-relay.sync
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="$HOME/Library/Application Support/agent-relay"
LOGS="$HOME/Library/Logs/agent-relay"
[ ! -e "$PLIST" ] && [ ! -e "$DEST" ] || { echo 'Existing install found; uninstall first' >&2; exit 1; }
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo 'Existing loaded job found; inspect it first' >&2; exit 1
fi
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
mkdir -p "$(dirname "$PLIST")" "$DEST" "$LOGS"
cp "$SCRIPT_DIR/sync.sh" "$DEST/sync.sh"
chmod 700 "$DEST/sync.sh"
# plutil safely encodes spaces and XML-sensitive characters.
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' > "$PLIST"
/usr/bin/plutil -insert Label -string "$LABEL" "$PLIST"
/usr/bin/plutil -insert ProgramArguments -array "$PLIST"
for arg in /bin/bash "$DEST/sync.sh" "$REPO" "$ORIGIN"; do
  /usr/bin/plutil -insert ProgramArguments -string "$arg" -append "$PLIST"
done
/usr/bin/plutil -insert StartInterval -integer 300 "$PLIST"
/usr/bin/plutil -insert RunAtLoad -bool true "$PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$LOGS/sync.log" "$PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$LOGS/sync-error.log" "$PLIST"
/usr/bin/plutil -lint "$PLIST"
chmod 600 "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL. Inspect $LOGS/sync.log; no agent is started."
