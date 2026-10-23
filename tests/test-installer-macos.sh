#!/bin/bash
# Validate real plist generation, but NEVER register a launchd service.
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'SKIP macOS installer test'; exit 0; }
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HOME="$TMP/home & space"
mkdir -p "$HOME" "$TMP/bin" "$TMP/work dir"
cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/bash
case "$1" in
  print) test -f "$HOME/mock-loaded-$(basename "$2")";;
  bootstrap) : > "$HOME/mock-loaded-$(basename "$3" .plist)";;
  bootout) rm -f "$HOME/mock-loaded-$(basename "$2")";;
  *) exit 99;;
esac
STUB
chmod +x "$TMP/bin/launchctl"
export PATH="$TMP/bin:$PATH"
REPO="$TMP/task & checkout"
git init -q -b main "$REPO"
git -C "$REPO" remote add origin git@github.com:example/tasks.git

# Pull-only install remains the default.
bash "$ROOT/scripts/macos/install.sh" "$REPO"
P="$HOME/Library/LaunchAgents/io.agent-relay.sync.plist"
R="$HOME/Library/LaunchAgents/io.agent-relay.runner.plist"
DEST="$HOME/Library/Application Support/agent-relay"
/usr/bin/plutil -lint "$P"
test "$(/usr/bin/plutil -extract ProgramArguments.2 raw "$P")" = "$(cd "$REPO" && pwd -P)"
test "$(/usr/bin/plutil -extract StartInterval raw "$P")" = 300
test ! -e "$R"
test ! -e "$DEST/relay-runner.sh"
if bash "$ROOT/scripts/macos/install.sh" "$REPO" >/dev/null 2>&1; then
  echo 'FAIL duplicate installation allowed'; exit 1
fi
bash "$ROOT/scripts/macos/uninstall.sh"
test ! -e "$P"
test ! -e "$R"
test -d "$REPO/.git"
test -d "$HOME/Library/Logs/agent-relay"

# Reserved runner environment variables must be rejected before installing.
if bash "$ROOT/scripts/macos/install.sh" "$REPO" --with-runner --runner-env PATH=/tmp >/dev/null 2>&1; then
  echo 'FAIL reserved runner variable accepted'; exit 1
fi
if bash "$ROOT/scripts/macos/install.sh" "$REPO" --with-runner --bogus >/dev/null 2>&1; then
  echo 'FAIL unknown argument accepted'; exit 1
fi
test ! -e "$P"
test ! -e "$R"

# Opt-in runner installation.
bash "$ROOT/scripts/macos/install.sh" "$REPO" --with-runner \
  --runner-env RELAY_EXECUTOR=paseo \
  --runner-env "RELAY_WORKSPACE_ALLOWLIST=$TMP/work dir"
/usr/bin/plutil -lint "$P"
/usr/bin/plutil -lint "$R"
test "$(/usr/bin/plutil -extract ProgramArguments.1 raw "$R")" = "$DEST/relay-runner.sh"
test "$(/usr/bin/plutil -extract ProgramArguments.2 raw "$R")" = "$(cd "$REPO" && pwd -P)"
test "$(/usr/bin/plutil -extract StartInterval raw "$R")" = 300
test "$(/usr/bin/plutil -extract RunAtLoad raw "$R")" = false
test "$(/usr/bin/plutil -extract EnvironmentVariables.RELAY_EXECUTOR raw "$R")" = paseo
test "$(/usr/bin/plutil -extract EnvironmentVariables.RELAY_WORKSPACE_ALLOWLIST raw "$R")" = "$TMP/work dir"
test "$(/usr/bin/plutil -extract EnvironmentVariables.RELAY_EXPECTED_ORIGIN raw "$R")" = git@github.com:example/tasks.git
test -x "$DEST/relay-runner.sh"
if bash "$ROOT/scripts/macos/install.sh" "$REPO" --with-runner >/dev/null 2>&1; then
  echo 'FAIL duplicate runner installation allowed'; exit 1
fi
# Runner state is preserved across uninstall.
mkdir -p "$HOME/Library/State/agent-relay/runner/launched"
: > "$HOME/Library/State/agent-relay/runner/launched/example-task"
bash "$ROOT/scripts/macos/uninstall.sh"
test ! -e "$P"
test ! -e "$R"
test ! -e "$DEST/sync.sh"
test ! -e "$DEST/relay-runner.sh"
test ! -e "$HOME/mock-loaded-io.agent-relay.sync"
test ! -e "$HOME/mock-loaded-io.agent-relay.runner"
test -d "$REPO/.git"
test -d "$HOME/Library/Logs/agent-relay"
test -f "$HOME/Library/State/agent-relay/runner/launched/example-task"

# Optional receipt notifier, installed on its own first.
N="$HOME/Library/LaunchAgents/io.agent-relay.receipt-notify.plist"
bash "$ROOT/scripts/macos/install.sh" "$REPO" --with-receipt-notify
/usr/bin/plutil -lint "$P"
/usr/bin/plutil -lint "$N"
test ! -e "$R"
test "$(/usr/bin/plutil -extract ProgramArguments.1 raw "$N")" = "$DEST/receipt-notify.sh"
test "$(/usr/bin/plutil -extract ProgramArguments.2 raw "$N")" = "$(cd "$REPO" && pwd -P)"
test "$(/usr/bin/plutil -extract StartInterval raw "$N")" = 300
test "$(/usr/bin/plutil -extract RunAtLoad raw "$N")" = true
test "$(/usr/bin/plutil -extract EnvironmentVariables.RELAY_STATE_DIR raw "$N")" = "$DEST"
test "$(/usr/bin/plutil -extract EnvironmentVariables.RELAY_LOG raw "$N")" = "$HOME/Library/Logs/agent-relay/receipt-notify.log"
test -x "$DEST/receipt-notify.sh"
test -f "$HOME/mock-loaded-io.agent-relay.receipt-notify"
if bash "$ROOT/scripts/macos/install.sh" "$REPO" --with-receipt-notify >/dev/null 2>&1; then
  echo 'FAIL duplicate receipt notifier installation allowed'; exit 1
fi
bash "$ROOT/scripts/macos/uninstall.sh"
test ! -e "$P"
test ! -e "$N"
test ! -e "$DEST/receipt-notify.sh"
test ! -e "$HOME/mock-loaded-io.agent-relay.receipt-notify"
test -d "$REPO/.git"

# All three jobs together, then uninstall removes every plist and script.
bash "$ROOT/scripts/macos/install.sh" "$REPO" --with-runner --with-receipt-notify
/usr/bin/plutil -lint "$P" "$R" "$N"
test -f "$HOME/mock-loaded-io.agent-relay.sync"
test -f "$HOME/mock-loaded-io.agent-relay.runner"
test -f "$HOME/mock-loaded-io.agent-relay.receipt-notify"
bash "$ROOT/scripts/macos/uninstall.sh"
for f in "$P" "$R" "$N" "$DEST/sync.sh" "$DEST/relay-runner.sh" "$DEST/receipt-notify.sh"; do
  test ! -e "$f"
done
test ! -e "$HOME/mock-loaded-io.agent-relay.sync"
test ! -e "$HOME/mock-loaded-io.agent-relay.runner"
test ! -e "$HOME/mock-loaded-io.agent-relay.receipt-notify"
test -d "$REPO/.git"
echo 'PASS installer: escaped paths, plist structure, pull-only default, optional runner, optional receipt notifier, reserved env rejection, duplicate refusal, uninstall preserves repo/logs/state; launchctl mocked'
