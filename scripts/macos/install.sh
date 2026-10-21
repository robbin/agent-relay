#!/bin/bash
# Installs one or two user launchd jobs. Never modifies the task repository.
#
#   bash install.sh ABSOLUTE_CHECKOUT [--with-runner] [--runner-env KEY=VALUE]...
#
# Without --with-runner this keeps the original pull-only timer. With
# --with-runner it also installs the opt-in local auto-relay executor, which is
# still inert until a pending task explicitly matches its `- Executor:` field.
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'macOS required' >&2; exit 1; }
[ "$#" -ge 1 ] || { echo 'usage: bash install.sh ABSOLUTE_CHECKOUT [--with-runner] [--runner-env KEY=VALUE]...' >&2; exit 1; }
REPO=$1
shift
WITH_RUNNER=0
RUNNER_ENV=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-runner) WITH_RUNNER=1 ;;
    --runner-env)
      [ "$#" -ge 2 ] || { echo '--runner-env requires KEY=VALUE' >&2; exit 1; }
      case "$2" in
        [A-Za-z_]*=*) ;;
        *) echo "--runner-env expects NAME=VALUE, got '$2'" >&2; exit 1;;
      esac
      RUNNER_ENV+=("$2")
      shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done
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

# Runner environment passed on the command line must not override paths or
# identity values that the installer itself pins.
if [ "${#RUNNER_ENV[@]}" -gt 0 ]; then
  for pair in "${RUNNER_ENV[@]}"; do
    NAME=${pair%%=*}
    VALUE=${pair#*=}
    case "$NAME" in
      HOME|PATH|LANG|LC_ALL|RELAY_REPO|RELAY_LOG|RELAY_SYNC_LOG|RELAY_STATE_DIR|RELAY_EXPECTED_ORIGIN)
        echo "reserved variable: $NAME" >&2; exit 1 ;;
      [A-Za-z_]*)
        case "$NAME" in *[!A-Za-z0-9_]*) echo "invalid variable name: $NAME" >&2; exit 1;; esac ;;
      *) echo "invalid variable name: $NAME" >&2; exit 1 ;;
    esac
    case "$VALUE" in *'
'*) echo "value for $NAME must not contain a newline" >&2; exit 1;; esac
  done
fi

LABEL=io.agent-relay.sync
RUNNER_LABEL=io.agent-relay.runner
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RUNNER_PLIST="$HOME/Library/LaunchAgents/$RUNNER_LABEL.plist"
DEST="$HOME/Library/Application Support/agent-relay"
LOGS="$HOME/Library/Logs/agent-relay"
RUNNER_STATE="$HOME/Library/State/agent-relay/runner"
[ ! -e "$PLIST" ] && [ ! -e "$RUNNER_PLIST" ] && [ ! -e "$DEST" ] || { echo 'Existing install found; uninstall first' >&2; exit 1; }
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo 'Existing loaded job found; inspect it first' >&2; exit 1
fi
if [ "$WITH_RUNNER" = 1 ] && launchctl print "gui/$(id -u)/$RUNNER_LABEL" >/dev/null 2>&1; then
  echo 'Existing loaded runner job found; inspect it first' >&2; exit 1
fi
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
[ -f "$SCRIPT_DIR/sync.sh" ] || { echo 'sync.sh missing next to installer' >&2; exit 1; }
if [ "$WITH_RUNNER" = 1 ]; then
  [ -f "$SCRIPT_DIR/relay-runner.sh" ] || { echo 'relay-runner.sh missing next to installer' >&2; exit 1; }
  bash -n "$SCRIPT_DIR/relay-runner.sh"
fi
mkdir -p "$(dirname "$PLIST")" "$DEST" "$LOGS"

# ---------------------------------------------------------------- pull-only timer
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

# ---------------------------------------------------------------- optional runner
if [ "$WITH_RUNNER" = 1 ]; then
  cp "$SCRIPT_DIR/relay-runner.sh" "$DEST/relay-runner.sh"
  chmod 700 "$DEST/relay-runner.sh"
  mkdir -p "$RUNNER_STATE"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' > "$RUNNER_PLIST"
  /usr/bin/plutil -insert Label -string "$RUNNER_LABEL" "$RUNNER_PLIST"
  /usr/bin/plutil -insert ProgramArguments -array "$RUNNER_PLIST"
  for arg in /bin/bash "$DEST/relay-runner.sh" "$REPO"; do
    /usr/bin/plutil -insert ProgramArguments -string "$arg" -append "$RUNNER_PLIST"
  done
  /usr/bin/plutil -insert StartInterval -integer 300 "$RUNNER_PLIST"
  /usr/bin/plutil -insert RunAtLoad -bool false "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables -dictionary "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables.PATH -string "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables.HOME -string "$HOME" "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables.LANG -string en_US.UTF-8 "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables.LC_ALL -string en_US.UTF-8 "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables.RELAY_EXPECTED_ORIGIN -string "$ORIGIN" "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables.RELAY_LOG -string "$LOGS/runner.log" "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables.RELAY_SYNC_LOG -string "$LOGS/sync.log" "$RUNNER_PLIST"
  /usr/bin/plutil -insert EnvironmentVariables.RELAY_STATE_DIR -string "$RUNNER_STATE" "$RUNNER_PLIST"
  if [ "${#RUNNER_ENV[@]}" -gt 0 ]; then
    for pair in "${RUNNER_ENV[@]}"; do
      /usr/bin/plutil -insert "EnvironmentVariables.${pair%%=*}" -string "${pair#*=}" "$RUNNER_PLIST"
    done
  fi
  /usr/bin/plutil -insert StandardOutPath -string "$LOGS/runner.log" "$RUNNER_PLIST"
  /usr/bin/plutil -insert StandardErrorPath -string "$LOGS/runner.log" "$RUNNER_PLIST"
  /usr/bin/plutil -insert ProcessType -string Background "$RUNNER_PLIST"
  /usr/bin/plutil -insert LowPriorityIO -bool true "$RUNNER_PLIST"
  /usr/bin/plutil -insert Nice -integer 5 "$RUNNER_PLIST"
  /usr/bin/plutil -insert ThrottleInterval -integer 60 "$RUNNER_PLIST"
  /usr/bin/plutil -insert AbandonProcessGroup -bool true "$RUNNER_PLIST"
  /usr/bin/plutil -lint "$RUNNER_PLIST"
  chmod 600 "$RUNNER_PLIST"
fi

launchctl bootstrap "gui/$(id -u)" "$PLIST"
if [ "$WITH_RUNNER" = 1 ]; then
  if ! launchctl bootstrap "gui/$(id -u)" "$RUNNER_PLIST"; then
    rm -f "$RUNNER_PLIST" "$DEST/relay-runner.sh"
    echo 'Runner bootstrap failed; removed its plist and installed script. Sync timer remains.' >&2
    exit 1
  fi
fi
echo "Installed $LABEL. Inspect $LOGS/sync.log; this timer only pulls."
if [ "$WITH_RUNNER" = 1 ]; then
  echo "Installed $RUNNER_LABEL. It dispatches only pending tasks that opt in with a matching '- Executor:' field; inspect $LOGS/runner.log. Test with RELAY_RUNNER_DRY_RUN=1 first."
fi
