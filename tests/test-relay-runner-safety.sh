#!/bin/bash
# F1-F6 regressions: cross-process execution evidence, pause failure modes,
# commit-message scanning, error injection and lock initialization.
# Every fixture lives in a temporary directory; there is no network remote, no
# model and no real credential.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY_TEST_FIXTURES_ONLY=1 source "$HERE/test-relay-runner-fixes.sh"
load_runner() { export RELAY_RUNNER_SOURCE_ONLY=1; source "$RUNNER"; unset RELAY_RUNNER_SOURCE_ONLY; }
quiet_push() { ( load_runner; push_guarded >"$T/push.log" 2>&1 ); }
unchanged() { [ "$(origin_head)" = "$H0" ]; }
make_done_executor() {
  cat >"$T/paseo" <<'P'
#!/bin/bash
set -eu
T="$(dirname "$0")"
if [ "${1:-} ${2:-}" = 'provider ls' ]; then echo 'pi available'; exit 0; fi
touch "$T/executed"
cd "$T/repo"
sed -i.bak 's/^- Status: accepted/- Status: done/' tasks/to-local/job.md
rm tasks/to-local/job.md.bak
git add tasks/to-local/job.md
if grep -q '^- Receipt: required' tasks/to-local/job.md; then
  printf '# Receipt: job\n\n- Task ID: job\n- Original task: tasks/to-local/job.md\n- Result status: done\n' >tasks/receipts/to-cloud/job.md
  git add tasks/receipts/to-cloud/job.md
fi
git commit -qm done
mode=$(cat "$T/outcome")
case "$mode" in
  directory) mkdir "$T/state/PAUSED"; exit 3 ;;
  dangling) ln -s "$T/missing" "$T/state/PAUSED"; exit 3 ;;
  fail) exit 3 ;;
  success) exit 0 ;;
esac
P
}

for mode in directory dangling fail; do
  setup "f1_$mode"; task job job $'- Receipt: required\n'; make_done_executor; echo "$mode" >"$T/outcome"; run
  check "F1 $mode the executor really ran" test -e "$T/executed"
  check "F1 $mode the independent quarantine record is persisted" test -d "$T/repo/.git/agent-relay-execution/hold"
  check "F1 $mode no push authorization was signed" test ! -e "$T/repo/.git/agent-relay-execution/approved-head"
  check "F1 $mode the remote keeps accepted" bash -c 'git -C "$1" show main:tasks/to-local/job.md | grep -q "^- Status: accepted"' _ "$T/origin.git"
  cp "$T/repo/tasks/to-local/job.md" "$T/task.before"
  cp "$T/repo/tasks/receipts/to-cloud/job.md" "$T/receipt.before"
  if [ "$mode" = directory ]; then rmdir "$T/state/PAUSED"; else rm "$T/state/PAUSED"; fi
  H0="$(origin_head)"; run
  check "F1 $mode a new process still refuses after PAUSED alone is deleted" unchanged
  check "F1 $mode the task keeps its exact bytes" cmp "$T/task.before" "$T/repo/tasks/to-local/job.md"
  check "F1 $mode the receipt keeps its exact bytes" cmp "$T/receipt.before" "$T/repo/tasks/receipts/to-cloud/job.md"
  rm -f "$T/state/PAUSED"
  quiet_push; rc=$?
  check "F1 $mode the direct push entry refuses too" test "$rc" != 0
  check "F1 $mode no wrong notification reaches the remote" unchanged
done

setup interrupted; task job job $'- Receipt: required\n'; make_done_executor; echo success >"$T/outcome"
( load_runner
  claim_task "$T/repo/tasks/to-local/job.md" tasks/to-local/job.md job >/dev/null 2>&1 || exit 9
  begin_execution job >/dev/null 2>&1 || exit 9
  "$T/paseo" run
  # The executor finished, but the runner exited before recording its result.
) || exit 1
H0="$(origin_head)"; run
check 'F1 an interrupted round cannot guess success without PAUSED' unchanged
check 'F1 the interrupted execution evidence is kept' test -d "$T/repo/.git/agent-relay-execution"

setup journalfail; task job job; touch "$T/repo/.git/agent-relay-execution"; run
check 'F1 the executor is not called when the evidence cannot be created' test ! -e "$T/paseo.args"
check 'F1 the unusable evidence path is not overwritten' test -f "$T/repo/.git/agent-relay-execution"

setup orphanreceipt; task job job $'- Receipt: required\n'; make_done_executor; echo success >"$T/outcome"
( load_runner; claim_task "$T/repo/tasks/to-local/job.md" tasks/to-local/job.md job >/dev/null 2>&1; "$T/paseo" run ) || exit 1
H0="$(origin_head)"; quiet_push; rc=$?
check 'F1 a leftover success receipt without evidence is not flushed' test "$rc" != 0
check 'F1 the unproven success receipt is not published' unchanged

setup successreceipt; task job job $'- Receipt: required\n'; make_done_executor; echo success >"$T/outcome"; run
check 'F1 a normal successful exit may push the done receipt' bash -c 'git -C "$1" show main:tasks/receipts/to-cloud/job.md | grep -q "Result status: done"' _ "$T/origin.git"
check 'F1 the finished execution evidence is cleared after the push' test ! -e "$T/repo/.git/agent-relay-execution"

setup retryapproved; task job job $'- Receipt: required\n'; make_done_executor; echo success >"$T/outcome"
( load_runner
  claim_task "$T/repo/tasks/to-local/job.md" tasks/to-local/job.md job >/dev/null 2>&1 || exit 9
  begin_execution job >/dev/null 2>&1 || exit 9
  "$T/paseo" run || exit 9
  git() { if [ "${1:-}" = push ]; then return 1; fi; command git "$@"; }
  complete_execution "$T/repo/tasks/to-local/job.md" tasks/to-local/job.md job >/dev/null 2>&1 ); rc=$?
check 'F1 a network failure keeps the exact-HEAD authorization' test -f "$T/repo/.git/agent-relay-execution/approved-head"
check 'F1 the network failure is not yet delivered' test "$rc" != 0
run
check 'F1 a new process may retry the same confirmed HEAD' bash -c 'git -C "$1" show main:tasks/receipts/to-cloud/job.md | grep -q "Result status: done"' _ "$T/origin.git"
check 'F1 the retry clears the evidence afterwards' test ! -e "$T/repo/.git/agent-relay-execution"

setup mismatchreceipt; task job job $'- Receipt: required\n'
( load_runner
  claim_task "$T/repo/tasks/to-local/job.md" tasks/to-local/job.md job >/dev/null 2>&1 || exit 9
  printf '# Receipt: job\n\n- Task ID: job\n- Original task: tasks/to-local/job.md\n- Result status: blocked\n' >"$T/repo/tasks/receipts/to-cloud/job.md"
  git -C "$T/repo" add tasks/receipts/to-cloud/job.md; git -C "$T/repo" commit -qm receipt
) || exit 1
H0="$(origin_head)"; quiet_push; rc=$?
check 'F1 the push entry re-checks task accepted / receipt blocked' test "$rc" != 0
check 'F1 a mismatched receipt is not published' unchanged

setup f3; task job job; make_done_executor; echo fail >"$T/outcome"; run
check 'F3 a one-way done plus an exit failure does not overwrite the done' grep -q '^- Status: done' "$T/repo/tasks/to-local/job.md"
check 'F3 the one-way unverified done is not pushed' bash -c 'git -C "$1" show main:tasks/to-local/job.md | grep -q "^- Status: accepted"' _ "$T/origin.git"
check 'F3 the one-way task also records evidence for verification' test -d "$T/repo/.git/agent-relay-execution/hold"

setup f2; task job job
( load_runner
  grep() { case "${1:-}" in -Eqi) return 2 ;; esac; command grep "$@"; }
  guard_scan "$T/repo/tasks/to-local/job.md"; test "$?" = 2 ); rc=$?
check 'F2 a body grep error is reported as a failed check' test "$rc" = 0
( load_runner
  grep() { case "${1:-}" in -Eqi) return 2 ;; esac; command grep "$@"; }
  main >"$T/main.log" 2>&1 )
check 'F2 a scan error does not dispatch' test ! -e "$T/paseo.args"
check 'F2 a scan error records blocked' grep -q '^- Status: blocked' "$T/repo/tasks/to-local/job.md"
( load_runner
  printf '# Task\n- Task: read the password.\n\n## Result\n' >"$T/chinese.md"
  guard_scan "$T/chinese.md"; test "$?" = 1 ); rc=$?
check 'F2 a non-ASCII sensitive word still matches' test "$rc" = 0
( load_runner
  printf '# ASCII task\n- Task: Read PASSWORD\n\n## Result\n' >"$T/ascii.md"
  guard_scan "$T/ascii.md"; test "$?" = 1 ); rc=$?
check 'F2 ASCII case folding still matches' test "$rc" = 0
( load_runner
  awk() { return 2; }; guard_scan "$T/ascii.md"; test "$?" = 2 ); rc=$?
check 'F2 a failed body extraction is refused' test "$rc" = 0

for variant in title body empty author; do
  setup "f4_$variant"
  ( set -e; cd "$T/repo"
    case "$variant" in
      title) echo safe >safe; git add safe; git commit -qm "$FAKE_SECRET" ;;
      body) echo safe >safe; git add safe; git commit -qm safe -m "$FAKE_SECRET" ;;
      empty) git commit --allow-empty -qm "$FAKE_SECRET" ;;
      author) git -c user.name="$FAKE_SECRET" commit --allow-empty -qm safe ;;
    esac
  ) || exit 1
  H0="$(origin_head)"; run
  check "F4 the invalid test value in the commit $variant is refused" unchanged
  check "F4 the commit $variant creates a pause" test -f "$T/state/PAUSED"
done
setup f4_error
( cd "$T/repo" && git commit --allow-empty -qm safe ) || exit 1
( load_runner
  git() { if [ "${1:-}" = 'cat-file' ] && [ "${2:-}" = commit ]; then return 2; fi; command git "$@"; }
  scan_pending_commits; test "$?" = 2 ); rc=$?
check 'F4 a commit metadata read error is refused' test "$rc" = 0
( load_runner
  grep() { if [ "${1:-}" = '-a' ]; then return 2; fi; command grep "$@"; }
  scan_pending_commits; test "$?" = 2 ); rc=$?
check 'F4 a commit metadata match error is refused' test "$rc" = 0

setup f5
( load_runner
  write_pause first >/dev/null; cp "$PAUSE_FILE" "$T/pause.before"
  write_pause second >/dev/null; cmp "$PAUSE_FILE" "$T/pause.before" ); rc=$?
check 'F5 an existing pause reason is not overwritten' test "$rc" = 0
rm "$T/state/PAUSED"; mkdir "$T/state/PAUSED"
( load_runner; write_pause failure >/dev/null 2>&1 ); rc=$?
check 'F5 writing fails clearly when PAUSED is a directory' test "$rc" != 0
check 'F5 a PAUSED directory still counts as a pause' bash -c 'export RELAY_RUNNER_SOURCE_ONLY=1; source "$1"; pause_present' _ "$RUNNER"
rmdir "$T/state/PAUSED"; ln -s "$T/missing" "$T/state/PAUSED"
( load_runner; write_pause failure >/dev/null 2>&1 ); rc=$?
check 'F5 the runner does not write through a dangling symlink' test "$rc" != 0
check 'F5 the symlink target is not created' test ! -e "$T/missing"
check 'F5 a dangling symlink still counts as a pause' bash -c 'export RELAY_RUNNER_SOURCE_ONLY=1; source "$1"; pause_present' _ "$RUNNER"
rm "$T/state/PAUSED"
( load_runner; PAUSE_FILE="$T/no-parent/PAUSED"; write_pause failure >/dev/null 2>&1 ); rc=$?
check 'F5 writing fails clearly when the directory is missing' test "$rc" != 0
( load_runner; write_pause first >/dev/null ) & p1=$!
( load_runner; write_pause second >/dev/null ) & p2=$!
wait "$p1"; wait "$p2"
check 'F5 concurrent creation keeps exactly one complete reason' test "$(grep -c '^Reason: ' "$T/state/PAUSED")" = 1

# The run lock is never reclaimed automatically: a missing, malformed or dead
# pid does not prove that no executor is still running.
for variant in no_pid bad_pid dead_pid live_pid; do
  setup "f6_$variant"; task job job; mkdir "$T/state/run.lock"
  case "$variant" in
    no_pid) ;;
    bad_pid) echo not-a-pid >"$T/state/run.lock/pid" ;;
    dead_pid) echo 999999999 >"$T/state/run.lock/pid" ;;
    live_pid) echo "$$" >"$T/state/run.lock/pid" ;;
  esac
  H0="$(origin_head)"; run
  check "F6 $variant the lock is not removed automatically" test -d "$T/state/run.lock"
  check "F6 $variant nothing is claimed or pushed" unchanged
  check "F6 $variant the executor is not called" test ! -e "$T/paseo.args"
done
setup f6_delayed; task job job; mkdir "$T/state/run.lock"
( sleep 3; printf '%s\n' "$$" >"$T/state/run.lock/pid" ) & writer=$!
run; wait "$writer"
check 'F6 a lock initialized after two seconds is still left alone' test "$(cat "$T/state/run.lock/pid")" = "$$"
check 'F6 the initialization window dispatches nothing' test ! -e "$T/paseo.args"
setup f6_own
( load_runner; acquire_run_lock && release_run_lock ) >"$T/lock.log" 2>&1; rc=$?
check 'F6 a lock created by this round is released normally' test "$rc" = 0
check 'F6 a normal release leaves nothing behind' test ! -e "$T/state/run.lock"

setup async; task job job
RELAY_GUARD_WAIT=0 bash "$RUNNER" "$T/repo" >"$T/async.log" 2>&1; rc=$?
check 'F6 asynchronous mode without a final exit status refuses to start' test "$rc" != 0
check 'F6 asynchronous mode dispatches nothing' test ! -e "$T/paseo.args"

# Review findings: carrying another control-file change along with the current
# task must refuse the whole push.
for probe in other_done other_blocked published_fork delete_task rename_task \
             reverse_add reverse_edit reverse_delete cloud_add cloud_edit cloud_delete \
             protocol own_missing_receipt own_remove_requirement; do
  setup "review_$probe"
  extra=''; case "$probe" in own_*) extra=$'- Receipt: required\n' ;; esac
  task job job "$extra"; task other other $'- Receipt: required\n'
  (
    set -e; cd "$T/repo"; mkdir -p tasks/receipts/to-local tasks/to-cloud
    printf '# Cloud receipt\n\n- Task ID: remote\n- Result status: done\n- Summary: original\n' >tasks/receipts/to-local/remote.md
    echo cloud >tasks/to-cloud/remote.md
    if [ "$probe" = published_fork ]; then
      sed -i.bak 's/^- Status: pending/- Status: done/' tasks/to-local/other.md; rm tasks/to-local/other.md.bak
      printf '# Receipt: other\n\n- Task ID: other\n- Original task: tasks/to-local/other.md\n- Result status: done\n' >tasks/receipts/to-cloud/other.md
    fi
    if [ "$probe" = other_blocked ]; then
      sed -i.bak 's/^- Status: pending/- Status: accepted/' tasks/to-local/other.md; rm tasks/to-local/other.md.bak
    fi
    git add tasks; git commit -qm setup; git push -q origin main
  ) || exit 1
  echo "$probe" >"$T/probe"
  cat >"$T/paseo" <<'P'
#!/bin/bash
set -eu
T="$(dirname "$0")"
if [ "${1:-} ${2:-}" = 'provider ls' ]; then echo 'pi available'; exit 0; fi
cd "$T/repo"
sed -i.bak 's/^- Status: accepted/- Status: done/' tasks/to-local/job.md; rm tasks/to-local/job.md.bak
case "$(cat "$T/probe")" in
  other_done) sed -i.bak 's/^- Status: pending/- Status: done/' tasks/to-local/other.md; rm tasks/to-local/other.md.bak ;;
  other_blocked) sed -i.bak 's/^- Status: accepted/- Status: blocked/' tasks/to-local/other.md; rm tasks/to-local/other.md.bak ;;
  published_fork) sed -i.bak 's/^- Status: done/- Status: blocked/' tasks/to-local/other.md; rm tasks/to-local/other.md.bak ;;
  delete_task) git rm -q tasks/to-local/other.md ;;
  rename_task) git mv tasks/to-local/other.md tasks/to-local/renamed.md ;;
  reverse_add) echo forged >tasks/receipts/to-local/new.md ;;
  reverse_edit) echo changed >>tasks/receipts/to-local/remote.md ;;
  reverse_delete) git rm -q tasks/receipts/to-local/remote.md ;;
  cloud_add) echo forged >tasks/to-cloud/new.md ;;
  cloud_edit) echo changed >>tasks/to-cloud/remote.md ;;
  cloud_delete) git rm -q tasks/to-cloud/remote.md ;;
  protocol) echo changed >>tasks/README.md ;;
  own_remove_requirement) sed -i.bak '/^- Receipt: required/d' tasks/to-local/job.md; rm tasks/to-local/job.md.bak ;;
  own_missing_receipt) : ;;
esac
git add tasks; git commit -qm mixed-result
exit 0
P
  run
  check "review $probe the current task result is not published either" bash -c 'git -C "$1" show main:tasks/to-local/job.md | grep -q "^- Status: accepted"' _ "$T/origin.git"
  check "review $probe a pause marker is written" test -f "$T/state/PAUSED"
  check "review $probe the execution evidence is kept" test -d "$T/repo/.git/agent-relay-execution"
  H0="$(origin_head)"; rm "$T/state/PAUSED"; run
  check "review $probe deleting PAUSED and retrying is refused too" unchanged
done

# Inject the mkdir error of begin_execution instead of pre-placing a record.
setup begin_mkdir_error; task job job
( load_runner
  mkdir() { case "${1:-}" in */.git/agent-relay-execution) return 1 ;; *) command mkdir "$@" ;; esac; }
  main >"$T/mkdir-error.log" 2>&1 ); rc=$?
check 'begin mkdir error ends the round with a non-zero exit' test "$rc" != 0
check 'begin mkdir error does not start the executor' test ! -e "$T/paseo.args"
check 'begin mkdir error writes a pause instead of stalling silently' test -f "$T/state/PAUSED"
check 'begin mkdir error really happens after the claim' bash -c 'git -C "$1" show main:tasks/to-local/job.md | grep -q "^- Status: accepted"' _ "$T/origin.git"

setup cleanup_error; task job job; make_done_executor; echo success >"$T/outcome"
( load_runner
  rmdir() { case "${1:-}" in */.git/agent-relay-execution) return 1 ;; *) command rmdir "$@" ;; esac; }
  main >"$T/cleanup-error.log" 2>&1 ); rc=$?
check 'a cleanup failure is reported as non-zero' test "$rc" != 0
check 'after the cleanup failure the remote really received done' bash -c 'git -C "$1" show main:tasks/to-local/job.md | grep -q "^- Status: done"' _ "$T/origin.git"
check 'the cleanup failure pauses for verification' test -f "$T/state/PAUSED"
check 'the cleanup failure keeps the incomplete record' test -d "$T/repo/.git/agent-relay-execution"
rm "$T/state/PAUSED"; H0="$(origin_head)"; run
check 'HEAD equal to origin with leftover evidence claims nothing' unchanged
check 'leftover evidence with HEAD at origin pauses again' test -f "$T/state/PAUSED"

setup dirty_executor; task job job
cat >"$T/paseo" <<'P'
#!/bin/bash
if [ "${1:-} ${2:-}" = 'provider ls' ]; then echo 'pi available'; exit 0; fi
T="$(dirname "$0")"
echo unfinished >"$T/repo/uncommitted.txt"
exit 0
P
run
check 'uncommitted executor output keeps the scene' test -f "$T/repo/uncommitted.txt"
check 'uncommitted executor output is not reported as done' bash -c 'git -C "$1" show main:tasks/to-local/job.md | grep -q "^- Status: accepted"' _ "$T/origin.git"
check 'the unresolved execution record is kept' test -d "$T/repo/.git/agent-relay-execution"

setup diverged
( set -e; cd "$T/repo"; echo remote >remote.txt; git add remote.txt; git commit -qm remote; git push -q origin main
  git checkout -qb local HEAD~1; echo local >local.txt; git add local.txt; git commit -qm local; git branch -M main
) || exit 1
H0="$(origin_head)"; run
check 'a diverged checkout with local commits is not flushed' unchanged
check 'the diverged scene still has the local commit' test "$(git -C "$T/repo" rev-list --count origin/main..HEAD)" = 1

printf 'F1-F6 PASS=%s FAIL=%s (%s, Bash %s)\n' "$PASS" "$FAIL" "$(uname -s)" "$BASH_VERSION"
[ "$FAIL" = 0 ]
