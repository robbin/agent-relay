#!/bin/bash
# Offline self-test for the relay-runner review fixes.
# Everything runs in a temporary directory: a local bare repository acts as
# origin, the executor is a fake script, and fake secrets are assembled at run
# time. No network remote, no real ~/.paseo and no real service is touched.
# Usage: bash tests/test-relay-runner-fixes.sh
#
# The fixture part is shared: tests/test-relay-runner-safety.sh and
# tests/test-relay-runner-regressions.sh source this file with
# RELAY_TEST_FIXTURES_ONLY=1 and then load their own cases.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/../scripts/macos/relay-runner.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/relay-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# The fake secret is assembled at run time so this file has no secret literal.
FAKE_SECRET="ghp_$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)"

setup() { # a fresh environment per case
  T="$ROOT/$1"; mkdir -p "$T"
  export HOME="$T/home"; mkdir -p "$HOME/.local/bin"
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
  ( cd "$T/repo" && git config user.email t@example.invalid && git config user.name t &&
    git checkout -q -b main 2>/dev/null; mkdir -p tasks/to-local tasks/receipts/to-cloud &&
    echo "# README" > tasks/README.md && touch tasks/receipts/to-cloud/.keep &&
    git add -A && git commit -qm init && git push -q origin main )
  mkdir -p "$T/work" "$T/projects" "$T/state"
  cat >"$T/paseo" <<'P'
#!/bin/bash
T="$(dirname "$0")"
if [ "$1 $2" = "provider ls" ]; then echo "pi available"; exit 0; fi
printf '%s\n' "$@" >"$T/paseo.args"
mode="$(cat "$T/paseo.mode" 2>/dev/null || echo ok)"
cd "$T/repo" || exit 9
case "$mode" in
  fail) exit 3 ;;
  fail_secret) echo "token $FAKE_SECRET" > leak.txt; git add leak.txt; git commit -qm leak; exit 3 ;;
  ok) f="$(grep -l "^- Status: accepted" tasks/to-local/*.md | head -n1)"
      sed -i.bak 's/^- Status: accepted/- Status: done/' "$f"; rm -f "$f.bak"
      if grep -q '^- Receipt: required' "$f"; then
        id="$(basename "$f" .md)"
        printf '# Receipt: %s\n\n- Task ID: %s\n- Original task: tasks/to-local/%s.md\n- Result status: done\n' \
          "$id" "$id" "$id" >"tasks/receipts/to-cloud/$id.md"
        git add "tasks/receipts/to-cloud/$id.md"
      fi
      git commit -qm done -- tasks; exit 0 ;;
esac
P
  chmod +x "$T/paseo"
  touch "$T/sync.log"; touch -t "$(date -d '-120 sec' +%Y%m%d%H%M.%S 2>/dev/null || date -v-120S +%Y%m%d%H%M.%S)" "$T/sync.log"
  export RELAY_REPO="$T/repo" RELAY_LOG="$T/runner.log" RELAY_SYNC_LOG="$T/sync.log" \
    RELAY_STATE_DIR="$T/state" RELAY_EXECUTOR_BIN="$T/paseo" RELAY_PASEO_CONFIG="$T/nope.json" \
    RELAY_WORKSPACE_ALLOWLIST="$T/repo:$T/work" RELAY_PROJECTS_ROOT="$T/projects" \
    RELAY_PUSH_RETRY_DELAY=0 RELAY_GITLOCK_TRIES=2 RELAY_GITLOCK_SLEEP=0 FAKE_SECRET
  unset RELAY_GUARD_BLOB_ALLOW RELAY_PASEO_WORKSPACE
}
task() { # $1=filename/ID $2=task ID $3=extra header lines
  printf '# Test task %s\n\n- Task ID: %s\n- Status: pending\n- Updated: 2026-01-01T10:00:00+00:00\n- Executor: paseo\n%s- Task: Write one sentence.\n\n## Result\n' \
    "$1" "$2" "${3:-}" >"$T/repo/tasks/to-local/$1.md"
  ( cd "$T/repo" && git add -A && git commit -qm "add $1" && git push -q origin main )
}
run() { bash "$RUNNER" "$T/repo" >/dev/null 2>&1; echo $? >"$T/rc"; rc="$(cat "$T/rc")"; }
origin_has() { git -C "$T/origin.git" log --all -p | grep -q -- "$1"; }
origin_head() { git -C "$T/origin.git" rev-parse main; }
logged() { grep -q -- "$1" "$T/runner.log"; }

if [ "${RELAY_TEST_FIXTURES_ONLY:-0}" = 1 ]; then return 0; fi

echo "== 1 a failed dispatch still goes through the output gate"
setup t1; task t1 t1; echo fail_secret >"$T/paseo.mode"; run
check "1a the secret the executor committed before failing never reaches the remote" bash -c "! git -C '$T/origin.git' log --all -p | grep -q ghp_"
check "1b a pause marker was written" test -f "$T/state/PAUSED"
check "1c the log records the refused push" logged "push blocked"
setup t1b; task t1b t1b; echo fail >"$T/paseo.mode"; run
check "1d without a secret the failure path pushes blocked" bash -c "git -C '$T/origin.git' show main:tasks/to-local/t1b.md | grep -q 'Status: blocked'"

echo "== 2 per-commit, per-blob scan; large and binary files fail closed"
setup t2; ( cd "$T/repo" && echo "k $FAKE_SECRET" >s.txt && git add s.txt && git commit -qm a && git rm -q s.txt && git commit -qm b ); H0="$(origin_head)"; run
check "2a empty net diff, but an intermediate commit holds a secret: not pushed" test "$(origin_head)" = "$H0"
check "2b the refused flush is logged" logged "push blocked"
setup t2c; ( cd "$T/repo" && head -c 1100000 /dev/zero | tr '\0' 'a' >big.txt && git add big.txt && git commit -qm big ); H0="$(origin_head)"; run
check "2c a file over 1 MiB is not pushed" test "$(origin_head)" = "$H0"
setup t2d; ( cd "$T/repo" && printf 'a\000b' >x.bin && git add x.bin && git commit -qm bin ); H0="$(origin_head)"; run
check "2d a binary file is not pushed" test "$(origin_head)" = "$H0"
setup t2e; ( cd "$T/repo" && printf 'a\000b' >x.bin && git add x.bin && git commit -qm bin ); export RELAY_GUARD_BLOB_ALLOW='*.bin'; run
check "2e RELAY_GUARD_BLOB_ALLOW explicitly allows the binary file" test "$(origin_head)" = "$(git -C "$T/repo" rev-parse HEAD)"
setup t2f; ( cd "$T/repo" && echo hi >a.txt && git add a.txt && git commit -qm ok ); run
check "2f a clean local commit is flushed" test "$(origin_head)" = "$(git -C "$T/repo" rev-parse HEAD)"

echo "== 3 all Git writes take the shared lock and commit by path"
setup t3; task t3 t3; mkdir "$T/repo/.git/agent-relay-git.lock"; H0="$(origin_head)"; run
check "3a with the lock held nothing is claimed, committed or pushed" test "$(origin_head)" = "$H0" -a "$(git -C "$T/repo" rev-parse HEAD)" = "$H0"
check "3b another process's lock is not deleted" test -d "$T/repo/.git/agent-relay-git.lock"
rmdir "$T/repo/.git/agent-relay-git.lock"
setup t3c; task t3c t3c
( export RELAY_RUNNER_SOURCE_ONLY=1; source "$RUNNER"; cd "$T/repo"
  echo other >other.txt; git add other.txt; echo x >>tasks/to-local/t3c.md
  commit_push "test" tasks/to-local/t3c.md >/dev/null 2>&1 )
check "3c an unrelated staged path prevents the commit" test "$(git -C "$T/repo" rev-parse HEAD)" = "$(origin_head)"
check "3d the unrelated staged file stays staged, not committed" bash -c "git -C '$T/repo' diff --cached --name-only | grep -qx other.txt"
check "3e the lock was released" test ! -d "$T/repo/.git/agent-relay-git.lock"
check "3f the commit was pushed" test "$(origin_head)" = "$(git -C "$T/repo" rev-parse HEAD)"

echo "== 4 task ID validation"
for bad_id in '../evil' 'a/b' '.hidden' 'x..y' '-x' 'Upper'; do
  setup "t4$(printf '%s' "$bad_id" | tr -c 'a-z' '_')"; task badid "$bad_id"; H0="$(origin_head)"; run
  check "4 an illegal ID ('${bad_id}') is refused: not claimed, not pushed" test "$(origin_head)" = "$H0"
  check "4 an illegal ID ('${bad_id}') is logged" logged "unsafe Task ID"
  check "4 an illegal ID ('${bad_id}') leaves no lock or marker" bash -c "[ -z \"\$(ls -A '$T/repo/.git/agent-relay-task-locks' 2>/dev/null)\" ] && [ ! -e '$T/evil' ]"
done
check "4 a valid ID 2026-10-23-abc passes" bash -c 'export RELAY_RUNNER_SOURCE_ONLY=1; source "$1"; valid_task_id 2026-10-23-abc' _ "$RUNNER"

echo "== 5 a pre-dispatch block writes the requested receipt"
setup t5; task t5 t5 $'- Role: absent-role\n- Receipt: required\n'; run
check "5a the remote has tasks/receipts/to-cloud/t5.md" bash -c "git -C '$T/origin.git' show main:tasks/receipts/to-cloud/t5.md | grep -q 'Result status: blocked'"
check "5b the receipt names the task ID and original task" bash -c "git -C '$T/origin.git' show main:tasks/receipts/to-cloud/t5.md | grep -q 'Original task: tasks/to-local/t5.md'"
check "5c the task itself is blocked" bash -c "git -C '$T/origin.git' show main:tasks/to-local/t5.md | grep -q 'Status: blocked'"
setup t5d; task t5d t5d $'- Role: absent-role\n'; run
check "5d without '- Receipt: required' no receipt is written" bash -c "! git -C '$T/origin.git' show main:tasks/receipts/to-cloud/t5d.md >/dev/null 2>&1"

echo "== 6 executor arguments (workspace stays optional and configurable)"
setup t6; task t6 t6; echo ok >"$T/paseo.mode"; run
check "6a no --workspace is passed unless it is configured" bash -c "! grep -qx -- '--workspace' '$T/paseo.args'"
check "6b the executor cwd defaults to the task checkout" bash -c "grep -A1 -x -- '--cwd' '$T/paseo.args' | tail -n1 | grep -qx '$T/repo'"
check "6c the normal path pushes done after the output gate" bash -c "git -C '$T/origin.git' show main:tasks/to-local/t6.md | grep -q 'Status: done'"
setup t6d; task t6d t6d; echo ok >"$T/paseo.mode"; export RELAY_PASEO_WORKSPACE=ws-example; run
check "6d RELAY_PASEO_WORKSPACE is passed when configured" grep -qx ws-example "$T/paseo.args"

echo "== result: PASS=${PASS} FAIL=${FAIL} ($(uname -s), Bash ${BASH_VERSION}, offline)"
[ "$FAIL" = "0" ]
