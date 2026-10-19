#!/bin/bash
# Validate real plist generation, but NEVER register a launchd service.
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'SKIP macOS installer test'; exit 0; }
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HOME="$TMP/home & space"
mkdir -p "$HOME" "$TMP/bin"
cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/bash
case "$1" in
  print) test -f "$HOME/mock-loaded";;
  bootstrap) touch "$HOME/mock-loaded";;
  bootout) rm "$HOME/mock-loaded";;
  *) exit 99;;
esac
STUB
chmod +x "$TMP/bin/launchctl"
export PATH="$TMP/bin:$PATH"
REPO="$TMP/task & checkout"
git init -q -b main "$REPO"
git -C "$REPO" remote add origin git@github.com:example/tasks.git
bash "$ROOT/scripts/macos/install.sh" "$REPO"
P="$HOME/Library/LaunchAgents/io.agent-relay.sync.plist"
/usr/bin/plutil -lint "$P"
test "$(/usr/bin/plutil -extract ProgramArguments.2 raw "$P")" = "$(cd "$REPO" && pwd -P)"
test "$(/usr/bin/plutil -extract StartInterval raw "$P")" = 300
if bash "$ROOT/scripts/macos/install.sh" "$REPO" >/dev/null 2>&1; then
  echo 'FAIL duplicate installation allowed'; exit 1
fi
bash "$ROOT/scripts/macos/uninstall.sh"
test ! -e "$P"
test -d "$REPO/.git"
test -d "$HOME/Library/Logs/agent-relay"
echo 'PASS installer: escaped paths, plist structure, duplicate refusal, uninstall preserves repo/logs; launchctl mocked'
