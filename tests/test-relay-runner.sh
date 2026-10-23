#!/bin/bash
# Mocked dispatch tests for the optional local auto-relay runner.
# Uses a fake executor binary and disposable Git repositories only.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_COMMITTER_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) ;; *) fail "expected '$2' in runner output: $1";; esac; }
not_contains() { case "$1" in *"$2"*) fail "did not expect '$2' in runner output: $1";; *) ;; esac; }

git init --bare -q "$TMP/remote.git"
git init -q -b main "$TMP/seed"
git -C "$TMP/seed" remote add origin "$TMP/remote.git"
mkdir -p "$TMP/seed/tasks/to-local" "$TMP/seed/tasks/to-cloud" "$TMP/seed/tasks/receipts/to-cloud"
printf '# Task protocol for tests\n' > "$TMP/seed/tasks/README.md"
: > "$TMP/seed/tasks/to-local/.gitkeep"
: > "$TMP/seed/tasks/receipts/to-cloud/.gitkeep"
printf 'seed\n' > "$TMP/seed/data"
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm initial
git -C "$TMP/seed" push -qu origin main
git --git-dir="$TMP/remote.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMP/remote.git" "$TMP/local"
LOCAL=$TMP/local
GIT_DIR=$(git -C "$LOCAL" rev-parse --absolute-git-dir)

export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
mkdir -p "$HOME" "$TMP/bin" "$TMP/logs" "$TMP/state" "$TMP/work/inside" "$TMP/outside" "$TMP/projects/proj/sub"

# The fake executor behaves like a well-behaved agent: it reports the task it
# was given, marks it done, commits only that file and never pushes.
cat > "$TMP/bin/paseo" <<'STUB'
#!/bin/bash
{ for a in "$@"; do printf 'ARG:%s\n' "$a"; done; } >> "${FAKE_PASEO_CALLS:?}"
if [ "${1:-}" = provider ]; then
  printf 'NAME STATUS\n%s\n' "${FAKE_PASEO_PROVIDER_LINE:-pi available}"
  exit 0
fi
for last in "$@"; do :; done
printf '%s\n' "$last" > "${FAKE_PASEO_PROMPT:?}"
[ "${FAKE_PASEO_EXIT:-0}" = 0 ] || exit "${FAKE_PASEO_EXIT}"
f=$(grep -l '^- Status: accepted' "$FAKE_REPO"/tasks/to-local/*.md 2>/dev/null | head -n 1 || true)
[ -n "$f" ] || exit 0
sed -e 's/^- Status: .*/- Status: done/' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
git -C "$FAKE_REPO" add "tasks/to-local/$(basename "$f")"
git -C "$FAKE_REPO" commit -qm "Complete task $(basename "$f" .md)"
exit 0
STUB
chmod +x "$TMP/bin/paseo"

cat > "$TMP/bin/command-exec" <<'STUB'
#!/bin/bash
{ for a in "$@"; do printf 'ARG:%s\n' "$a"; done; } >> "${FAKE_CMD_CALLS:?}"
cat > "${FAKE_CMD_PROMPT:?}"
[ "${FAKE_CMD_EXIT:-0}" = 0 ] || exit "${FAKE_CMD_EXIT}"
f=$(grep -l '^- Status: accepted' "$FAKE_CMD_REPO"/tasks/to-local/*.md 2>/dev/null | head -n 1 || true)
[ -n "$f" ] || exit 0
sed -e 's/^- Status: .*/- Status: done/' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
git -C "$FAKE_CMD_REPO" add "tasks/to-local/$(basename "$f")"
git -C "$FAKE_CMD_REPO" commit -qm "Complete task $(basename "$f" .md)"
exit 0
STUB
chmod +x "$TMP/bin/command-exec"

export RELAY_LOG="$TMP/logs/runner.log"
export RELAY_SYNC_LOG="$TMP/logs/sync.log"
export RELAY_STATE_DIR="$TMP/state"
export RELAY_EXECUTOR_BIN="$TMP/bin/paseo"
export RELAY_EXPECTED_ORIGIN="$TMP/remote.git"
export RELAY_DEFAULT_PROVIDER="pi/test-model"
export RELAY_DEFAULT_THINKING="high"
export RELAY_WORKSPACE_ALLOWLIST="$TMP/work"
export RELAY_PROJECTS_ROOT="$TMP/projects"
export RELAY_PUSH_RETRY_DELAY=0
export RELAY_GITLOCK_TRIES=2
export RELAY_GITLOCK_SLEEP=0
: > "$RELAY_SYNC_LOG"

run_runner() {
  env FAKE_PASEO_CALLS="$TMP/calls" FAKE_PASEO_PROMPT="$TMP/prompt" FAKE_REPO="$LOCAL" \
      FAKE_CMD_CALLS="$TMP/calls" FAKE_CMD_PROMPT="$TMP/prompt" FAKE_CMD_REPO="$LOCAL" \
      "$@" bash "$ROOT/scripts/macos/relay-runner.sh" "$LOCAL"
}
clear_calls() { rm -f "$TMP/calls" "$TMP/prompt"; }
has_call() { [ -f "$TMP/calls" ] && grep -Fqx -- "$1" "$TMP/calls"; }
run_count() { if [ -f "$TMP/calls" ]; then grep -Fxc 'ARG:run' "$TMP/calls" || true; else echo 0; fi; }

sync_recent() { date -u '+%Y-%m-%dT%H:%M:%SZ' > "$RELAY_SYNC_LOG"; }
sync_valid() {
  local stamp
  stamp=$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')
  touch -t "$stamp" "$RELAY_SYNC_LOG"
}
sync_stale() { touch -t 202001010000.00 "$RELAY_SYNC_LOG"; }

add_task() { # $1=name [$2=extra fields] [$3=status]
  local name=$1 extra=${2:-} status=${3:-pending}
  {
    printf '# Test task %s\n\n' "$name"
    printf -- '- Task ID: %s\n' "$name"
    printf -- '- Status: %s\n' "$status"
    printf -- '- Updated: 2026-01-01T10:00:00+00:00\n'
    [ -n "$extra" ] && printf -- '%s\n' "$extra"
    printf -- '- Task: Write TEST-OK in Result.\n'
    printf -- '- Constraints: Only update this file.\n'
    printf -- '- Acceptance: Result contains TEST-OK.\n'
    printf -- '- Deliverable: Update Result and status.\n'
    printf '\n## Result\n'
  } > "$LOCAL/tasks/to-local/$name.md"
  git -C "$LOCAL" add "tasks/to-local/$name.md"
  git -C "$LOCAL" commit -qm "add $name"
  git -C "$LOCAL" push -q
}

drop_task() { # $1=name
  rm -rf "$RELAY_STATE_DIR/launched/$1" "$GIT_DIR/agent-relay-task-locks/$1"
  git -C "$LOCAL" rm -q "tasks/to-local/$1.md" 2>/dev/null || true
  if [ -n "$(git -C "$LOCAL" status --porcelain)" ]; then
    git -C "$LOCAL" commit -qm "drop $1"
    git -C "$LOCAL" push -q
  fi
}

reset_locks() { rm -rf "$GIT_DIR/agent-relay-task-locks" "$RELAY_STATE_DIR/launched" "$GIT_DIR/agent-relay-execution"; }
status_local() { awk '/^## Result$/ {exit} /^- Status:/ {sub(/^- Status:[ \t]*/, ""); print; exit}' "$LOCAL/tasks/to-local/$1.md"; }
status_remote() { git --git-dir="$TMP/remote.git" show "main:tasks/to-local/$1.md" | awk '/^## Result$/ {exit} /^- Status:/ {sub(/^- Status:[ \t]*/, ""); print; exit}'; }

# 1. Nothing to dispatch.
sync_valid
out=$(run_runner 2>&1 || true)
contains "$out" 'nothing to do'

# 2. Dry run changes nothing and does not execute the executor.
add_task dry-run-1 '- Executor: paseo'
clear_calls
out=$(run_runner RELAY_RUNNER_DRY_RUN=1 2>&1 || true)
contains "$out" '[dry-run]'
test "$(status_local dry-run-1)" = pending || fail 'dry run changed local status'
test "$(status_remote dry-run-1)" = pending || fail 'dry run pushed a status change'
test "$(run_count)" = 0 || fail 'dry run invoked the executor run command'
test ! -e "$RELAY_STATE_DIR/launched/dry-run-1" || fail 'dry run wrote a dispatch marker'
test ! -d "$GIT_DIR/agent-relay-task-locks/dry-run-1" || fail 'dry run left a task lock'
test ! -e "$GIT_DIR/agent-relay-execution" || fail 'dry run wrote execution evidence'
drop_task dry-run-1

# 3. Real dispatch: claim, narrow commit, executor args, done, marker.
add_task auto-1 '- Executor: paseo'
clear_calls
out=$(run_runner 2>&1 || true)
contains "$out" 'dispatch accepted: auto-1'
contains "$out" 'round complete'
test "$(status_remote auto-1)" = done || fail 'remote task not done'
test "$(git -C "$LOCAL" show --name-only --format= HEAD~1)" = 'tasks/to-local/auto-1.md' \
  || fail 'claim commit included more than the task file'
has_call 'ARG:run' || fail 'executor run missing'
has_call 'ARG:--no-wait' && fail 'guard-wait mode must not pass --no-wait'
has_call 'ARG:--title' || fail 'executor --title missing'
has_call 'ARG:auto-1' || fail 'executor task title missing'
has_call 'ARG:--provider' || fail 'executor provider missing'
has_call 'ARG:pi/test-model' || fail 'default provider not passed'
has_call 'ARG:--thinking' || fail 'executor thinking missing'
has_call 'ARG:high' || fail 'default thinking not passed'
has_call "ARG:$LOCAL" || fail 'checkout cwd not passed'
grep -q 'auto-1' "$TMP/prompt" || fail 'prompt does not name the task'
grep -qi 'prepare-only' "$TMP/prompt" || fail 'prompt lacks the prepare-only rule'
grep -q 'Do NOT git push' "$TMP/prompt" || fail 'prompt does not forbid pushing'
test -e "$RELAY_STATE_DIR/launched/auto-1" || fail 'dispatch marker missing'
test ! -d "$GIT_DIR/agent-relay-task-locks/auto-1" || fail 'task lock was not released'
test ! -e "$GIT_DIR/agent-relay-execution" || fail 'execution evidence not cleared after the push'
test -z "$(git -C "$LOCAL" status --porcelain)" || fail 'checkout left dirty'
test "$(git -C "$LOCAL" rev-parse HEAD)" = "$(git --git-dir="$TMP/remote.git" rev-parse main)" \
  || fail 'checkout is not at origin/main after the push'

# 4. Non-opted-in, blocked and accepted tasks are never claimed.
reset_locks
add_task manual-1 ''
add_task blocked-1 '- Executor: paseo' blocked
add_task accepted-1 '- Executor: paseo' accepted
clear_calls
out=$(run_runner 2>&1 || true)
contains "$out" 'nothing to do'
test "$(status_remote manual-1)" = pending || fail 'manual task was claimed'
test "$(status_remote blocked-1)" = blocked || fail 'blocked task was retried'
test "$(status_remote accepted-1)" = accepted || fail 'accepted task was retried'
test "$(run_count)" = 0 || fail 'executor ran for a non-eligible task'
drop_task manual-1; drop_task blocked-1; drop_task accepted-1

# 5. Dirty worktree is preserved and blocks dispatch.
add_task dirty-1 '- Executor: paseo'
echo dirty >> "$LOCAL/data"
sync_valid
clear_calls
out=$(run_runner 2>&1 || true)
contains "$out" 'dirty'
test "$(status_local dirty-1)" = pending || fail 'dirty worktree still claimed the task'
test "$(run_count)" = 0 || fail 'executor ran on a dirty worktree'
git -C "$LOCAL" checkout -- data
drop_task dirty-1

# 6. Timing gate: too recent and too stale sync logs both skip.
add_task timing-1 '- Executor: paseo'
sync_recent
out=$(run_runner 2>&1 || true)
contains "$out" 'yield to the sync timer'
sync_stale
out=$(run_runner 2>&1 || true)
contains "$out" 'stale data'
test "$(status_local timing-1)" = pending || fail 'timing gate still claimed the task'
drop_task timing-1

# 7. Target directory: allowed and outside the allowlist.
sync_valid
INSIDE=$(cd "$TMP/work/inside" && pwd -P)
add_task target-in "- Executor: paseo
- Target directory: $TMP/work/inside"
clear_calls
out=$(run_runner 2>&1 || true)
contains "$out" 'dispatch accepted: target-in'
has_call 'ARG:--cwd' || fail 'target directory not passed as --cwd'
has_call "ARG:$INSIDE" || fail 'resolved target directory not passed'
drop_task target-in

add_task target-out "- Executor: paseo
- Target directory: $TMP/outside"
clear_calls
out=$(run_runner 2>&1 || true)
contains "$out" 'outside the configured allowlist'
test "$(status_remote target-out)" = blocked || fail 'outside allowlist was not blocked remotely'
test "$(run_count)" = 0 || fail 'executor ran outside the allowlist'
test ! -d "$GIT_DIR/agent-relay-task-locks/target-out" || fail 'blocked target task left a task lock'
drop_task target-out

# 8. Executor failure becomes blocked and releases the task lock.
add_task fail-1 '- Executor: paseo'
clear_calls
out=$(run_runner FAKE_PASEO_EXIT=1 2>&1 || true)
contains "$out" 'dispatch failed: fail-1'
contains "$out" 'executor exit 1'
test "$(status_remote fail-1)" = blocked || fail 'executor failure not blocked remotely'
test ! -d "$GIT_DIR/agent-relay-task-locks/fail-1" || fail 'failed dispatch kept the task lock'
drop_task fail-1

# 9. Role presets, including a featureValues warning, are used without substitution.
cat > "$TMP/paseo-config.json" <<'JSON'
{"daemon":{"agentProfiles":[
  {"name":"reviewer","provider":"pi","model":"m1","modeId":"plan","thinkingOptionId":"high","notes":"Review carefully.","featureValues":{"permissionPreset":"example"}},
  {"name":"ghost","provider":"notlisted","model":"x","notes":"Should never run."}
]}}
JSON
add_task role-ok "- Executor: paseo
- Role: reviewer"
clear_calls
out=$(run_runner RELAY_PASEO_CONFIG="$TMP/paseo-config.json" 2>&1 || true)
contains "$out" 'dispatch accepted: role-ok'
has_call 'ARG:pi/m1' || fail 'role provider/model not passed'
has_call 'ARG:--mode' || fail 'role mode not passed'
has_call 'ARG:plan' || fail 'role mode value not passed'
grep -q 'Review carefully.' "$TMP/prompt" || fail 'role notes missing from prompt'
contains "$out" 'featureValues'
drop_task role-ok

add_task role-missing "- Executor: paseo
- Role: absent-role"
clear_calls
out=$(run_runner RELAY_PASEO_CONFIG="$TMP/paseo-config.json" 2>&1 || true)
contains "$out" 'role unavailable'
test "$(status_remote role-missing)" = blocked || fail 'unknown role was not blocked'
test "$(run_count)" = 0 || fail 'unknown role was replaced with a fallback provider'
grep -q 'absent-role' "$LOCAL/tasks/to-local/role-missing.md" || fail 'blocked task lost the role reason'
drop_task role-missing

add_task provider-missing "- Executor: paseo
- Role: ghost"
clear_calls
out=$(run_runner RELAY_PASEO_CONFIG="$TMP/paseo-config.json" 2>&1 || true)
contains "$out" 'provider unavailable'
test "$(status_remote provider-missing)" = blocked || fail 'unavailable provider was not blocked'
test "$(run_count)" = 0 || fail 'unavailable provider still dispatched'
drop_task provider-missing

# 10. Configurable command adapter receives the task ID and the prompt on stdin.
add_task cmd-1 '- Executor: command'
clear_calls
out=$(run_runner RELAY_EXECUTOR=command RELAY_EXECUTOR_BIN="$TMP/bin/command-exec" 2>&1 || true)
contains "$out" 'dispatch accepted: cmd-1'
has_call 'ARG:--task-id' || fail 'command adapter task ID flag missing'
has_call 'ARG:cmd-1' || fail 'command adapter task ID value missing'
grep -q 'cmd-1' "$TMP/prompt" || fail 'command adapter prompt missing task ID'
test "$(status_remote cmd-1)" = done || fail 'command adapter dispatch was not completed'
drop_task cmd-1

# 11. Pause marker stops dispatch.
add_task pause-1 '- Executor: paseo'
: > "$RELAY_STATE_DIR/PAUSED"
clear_calls
out=$(run_runner 2>&1 || true)
contains "$out" 'pause marker'
test "$(status_local pause-1)" = pending || fail 'pause marker ignored'
test "$(run_count)" = 0 || fail 'executor ran while paused'
rm -f "$RELAY_STATE_DIR/PAUSED"
drop_task pause-1

# 12. A run lock is never reclaimed automatically; a matching Task ID is required.
mkdir -p "$RELAY_STATE_DIR/run.lock"
echo 999999999 > "$RELAY_STATE_DIR/run.lock/pid"
out=$(run_runner 2>&1 || true)
contains "$out" 'run lock'
test -d "$RELAY_STATE_DIR/run.lock" || fail 'runner removed a run lock it did not create'
rm -rf "$RELAY_STATE_DIR/run.lock"

{
  printf '# Bad task\n\n- Task ID: other-id\n- Status: pending\n- Updated: 2026-01-01T10:00:00+00:00\n'
  printf -- '- Executor: paseo\n\n## Result\n'
} > "$LOCAL/tasks/to-local/mismatch-1.md"
git -C "$LOCAL" add tasks/to-local/mismatch-1.md
git -C "$LOCAL" commit -qm 'add mismatched task'
git -C "$LOCAL" push -q
sync_valid
clear_calls
out=$(run_runner 2>&1 || true)
contains "$out" 'filename and ID differ'
test "$(status_local mismatch-1)" = pending || fail 'mismatched task ID was claimed'
test "$(run_count)" = 0 || fail 'executor ran for a mismatched task ID'
git -C "$LOCAL" rm -q tasks/to-local/mismatch-1.md
git -C "$LOCAL" commit -qm 'drop mismatch task'
git -C "$LOCAL" push -q

# 13. A wrong expected origin is refused before any dispatch.
add_task origin-1 '- Executor: paseo'
clear_calls
out=$(run_runner RELAY_EXPECTED_ORIGIN="$TMP/other-remote.git" 2>&1 || true)
contains "$out" 'RELAY_EXPECTED_ORIGIN'
test "$(run_count)" = 0 || fail 'executor ran with an unexpected origin'
test "$(status_local origin-1)" = pending || fail 'unexpected origin still claimed the task'
drop_task origin-1

# 14. A checkout that is behind origin/main is left to the sync timer.
add_task behind-1 '- Executor: paseo'
( git clone -q "$TMP/remote.git" "$TMP/other" && cd "$TMP/other" \
  && printf '# remote note\n' > remote-note.md && git add -A \
  && git commit -qm 'remote move' && git push -q origin main )
sync_valid
clear_calls
out=$(run_runner 2>&1 || true)
contains "$out" 'behind'
test "$(run_count)" = 0 || fail 'executor ran on a checkout that is behind origin/main'
git -C "$LOCAL" fetch -q origin
git -C "$LOCAL" reset --hard -q origin/main
reset_locks
git -C "$LOCAL" rm -q tasks/to-local/behind-1.md 2>/dev/null || true
git -C "$LOCAL" commit -qm 'drop behind task' 2>/dev/null || true
git -C "$LOCAL" push -q

echo 'PASS relay-runner: dry-run, claim/commit/push, dispatch args and prompt, done after the output gate, marker, opt-in/blocked/accepted filtering, dirty/sync/behind gates, allowlist, executor failure, role/provider presets, command adapter, pause, run lock, mismatched ID, expected origin; executor mocked'
