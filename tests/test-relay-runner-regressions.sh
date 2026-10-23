#!/bin/bash
# Acceptance regressions: only a temporary HOME, a local bare origin, a fake
# executor and invalid test values are used. Offline; no network, no model.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY_TEST_FIXTURES_ONLY=1 source "$HERE/test-relay-runner-fixes.sh"
load_runner() { export RELAY_RUNNER_SOURCE_ONLY=1; source "$RUNNER"; unset RELAY_RUNNER_SOURCE_ONLY; }
quiet_push() { ( load_runner; push_guarded >"$T/push.log" 2>&1 ); }
unchanged() { [ "$(origin_head)" = "$H0" ]; }

setup merge
( set -e; cd "$T/repo"; git checkout -qb side; echo side >side.txt; git add side.txt; git commit -qm side
  git checkout -q main; echo main >main.txt; git add main.txt; git commit -qm main
  git merge --no-ff --no-commit side >/dev/null 2>&1
  printf '%s\n' "$FAKE_SECRET" >merge-only.txt; git add merge-only.txt; git commit -qm merge ) || exit 1
H0="$(origin_head)"; quiet_push; rc=$?
check 'a merge-only new blob is refused' test "$rc" != 0
check 'a merge-only commit does not change origin' unchanged

setup body; task body body
( load_runner
  claim_task "$T/repo/tasks/to-local/body.md" tasks/to-local/body.md body >/dev/null 2>&1 || exit 9
  begin_execution body >/dev/null 2>&1 || exit 9
  sed -i.bak 's/^- Status: accepted/- Status: done/' "$T/repo/tasks/to-local/body.md"; rm "$T/repo/tasks/to-local/body.md.bak"
  printf '\n## Additional material\n%s\n' "$FAKE_SECRET" >>"$T/repo/tasks/to-local/body.md"
  git -C "$T/repo" commit -qm body -- tasks/to-local/body.md
  complete_execution "$T/repo/tasks/to-local/body.md" tasks/to-local/body.md body >"$T/push.log" 2>&1 ); rc=$?
check 'another section of the same task file is scanned too' test "$rc" != 0
check 'the remote task body has no test value' bash -c '! git -C "$1" show main:tasks/to-local/body.md | grep -q ghp_' _ "$T/origin.git"

setup branch; task branch branch; H0="$(origin_head)"
( load_runner; repo_ready >/dev/null; git -C "$T/repo" checkout -qb unrelated
  echo unrelated >"$T/repo/unrelated.txt"; git -C "$T/repo" add unrelated.txt; git -C "$T/repo" commit -qm unrelated
  claim_task "$T/repo/tasks/to-local/branch.md" tasks/to-local/branch.md branch >"$T/claim.log" 2>&1 ); rc=$?
check 'switching branch after the pre-check makes the locked claim fail' test "$rc" != 0
check 'no unrelated branch is pushed' unchanged
check 'the task status is untouched' grep -q '^- Status: pending' "$T/repo/tasks/to-local/branch.md"
check 'the shared lock of the failed attempt is released' test ! -d "$T/repo/.git/agent-relay-git.lock"

setup state; task state state
( load_runner; repo_ready >/dev/null
  sed -i.bak 's/^- Status: pending/- Status: done/' "$T/repo/tasks/to-local/state.md"; rm "$T/repo/tasks/to-local/state.md.bak"
  git -C "$T/repo" commit -qm closed -- tasks/to-local/state.md; git -C "$T/repo" push -q origin main
  claim_task "$T/repo/tasks/to-local/state.md" tasks/to-local/state.md state >"$T/claim.log" 2>&1 ); rc=$?
check 'the locked claim re-checks the status and does not claim done again' test "$rc" != 0
check 'the done status is kept' grep -q '^- Status: done' "$T/repo/tasks/to-local/state.md"

setup mismatch; task filename different; H0="$(origin_head)"; run
check 'a legal ID that differs from the filename is not dispatched' test ! -e "$T/paseo.args"
check 'a mismatched ID creates no commit' unchanged

setup greperror
( cd "$T/repo" && echo normal >normal.txt && git add normal.txt && git commit -qm normal ) || exit 1
( load_runner
  grep() { if [ "${1:-}" = '-E' ] && [ "${2:-}" = '--' ]; then return 2; fi; command grep "$@"; }
  scan_pending_commits; test "$?" = 2 ); rc=$?
check 'a pattern grep error fails closed' test "$rc" = 0
( load_runner
  grep() { if [ "${1:-}" = '-I' ]; then return 2; fi; command grep "$@"; }
  scan_pending_commits; test "$?" = 2 ); rc=$?
check 'a text-detection grep error fails closed' test "$rc" = 0
( load_runner
  git() { if [ "${1:-}" = 'diff-tree' ]; then return 2; fi; command git "$@"; }
  scan_pending_commits; test "$?" = 2 ); rc=$?
check 'a diff-tree error fails closed' test "$rc" = 0
( load_runner
  git() { if [ "${1:-}" = 'cat-file' ] && [ "${2:-}" = 'blob' ]; then return 2; fi; command git "$@"; }
  scan_pending_commits; test "$?" = 2 ); rc=$?
check 'a blob read error fails closed' test "$rc" = 0
( load_runner
  git() { if [ "${1:-}" = 'rev-list' ]; then return 2; fi; command git "$@"; }
  scan_pending_commits; test "$?" = 2 ); rc=$?
check 'a rev-list error fails closed' test "$rc" = 0

setup filenames
( cd "$T/repo" && printf '%s\n' "$FAKE_SECRET" >$'spaces tab\t newline\n.txt' && git add . && git commit -qm weird ) || exit 1
H0="$(origin_head)"; quiet_push; rc=$?
check 'a path with tab and newline is still scanned' test "$rc" != 0
check 'the special path is not pushed' unchanged

setup benign
( cd "$T/repo" && printf '\n\n' >blank.txt && touch empty.txt && echo hi >$'spaces tab\t newline\n.txt' && git add . && git commit -qm benign ) || exit 1
quiet_push; rc=$?
check 'empty, blank and special-path safe text can be pushed' test "$rc" = 0

setup headchange
( cd "$T/repo" && echo hi >a.txt && git add a.txt && git commit -qm first ) || exit 1
H0="$(origin_head)"
( load_runner
  eval "$(declare -f scan_pending_commits | sed '1s/scan_pending_commits/real_scan/')"
  scan_pending_commits() { real_scan "$@" || return $?; echo later >later.txt; git add later.txt; git commit -qm later; }
  push_guarded >"$T/push.log" 2>&1 ); rc=$?
check 'a HEAD change after the scan refuses the push' test "$rc" != 0
check 'origin is unchanged when HEAD moved' unchanged

setup lockheld; task lockheld lockheld
mkdir "$T/repo/.git/agent-relay-git.lock"; run
check 'with the lock held the task stays pending instead of being claimed first' grep -q '^- Status: pending' "$T/repo/tasks/to-local/lockheld.md"
check 'another process lock is not deleted' test -d "$T/repo/.git/agent-relay-git.lock"

setup receipt; task receipt receipt $'- Receipt: required\n'
printf '#!/bin/bash\nif [ "$1 $2" = "provider ls" ]; then echo "pi available"; exit 0; fi\ntouch "$(dirname "$0")/executed"\nexit 3\n' >"$T/paseo"
run
check 'the fake executor really ran' test -e "$T/executed"
check 'the failure receipt says side effects are possible' bash -c 'git -C "$1" show main:tasks/receipts/to-cloud/receipt.md | grep -q "partial side effects"' _ "$T/origin.git"
check 'a post-dispatch failure never claims the task was not executed' bash -c '! git -C "$1" show main:tasks/receipts/to-cloud/receipt.md | grep -q "the task was not executed"' _ "$T/origin.git"

setup receipt_error; task receipt-error receipt-error $'- Receipt: required\n'
( load_runner
  claim_task "$T/repo/tasks/to-local/receipt-error.md" tasks/to-local/receipt-error.md receipt-error >/dev/null 2>&1
  write_blocked_receipt() { return 2; }
  block_task "$T/repo/tasks/to-local/receipt-error.md" tasks/to-local/receipt-error.md receipt-error failure >"$T/block.log" 2>&1 ); rc=$?
check 'a receipt error never degrades into pushing the state alone' test "$rc" != 0
check 'the remote stays accepted when the receipt fails' bash -c 'git -C "$1" show main:tasks/to-local/receipt-error.md | grep -q "^- Status: accepted"' _ "$T/origin.git"

setup cleancommit; task cleancommit cleancommit
( load_runner; echo x >"$T/repo/material.txt"; commit_push exact material.txt >"$T/push.log" 2>&1 ); rc=$?
check 'an exact commit works when the index has nothing unrelated' test "$rc" = 0
check 'the exact commit contains only the target path' test "$(git -C "$T/repo" show --name-only --format= HEAD)" = material.txt

# Review R1: the executor commits done plus a done receipt and then fails; the
# local result must be kept instead of being pushed.
setup failedreceipt; task failedreceipt failedreceipt $'- Receipt: required\n'
cat >"$T/paseo" <<'P'
#!/bin/bash
if [ "$1 $2" = 'provider ls' ]; then echo 'pi available'; exit 0; fi
T="$(dirname "$0")"
cd "$T/repo" || exit 9
sed -i.bak 's/^- Status: accepted/- Status: done/' tasks/to-local/failedreceipt.md
rm tasks/to-local/failedreceipt.md.bak
printf '# Receipt: failedreceipt\n\n- Task ID: failedreceipt\n- Original task: tasks/to-local/failedreceipt.md\n- Result status: done\n' >tasks/receipts/to-cloud/failedreceipt.md
git add tasks/to-local/failedreceipt.md tasks/receipts/to-cloud/failedreceipt.md
git commit -qm 'done and receipt' || exit 9
exit 3
P
run
check 'done receipt committed before failing: the remote task stays accepted' bash -c 'git -C "$1" show main:tasks/to-local/failedreceipt.md | grep -q "^- Status: accepted"' _ "$T/origin.git"
check 'done receipt committed before failing: no wrong success receipt remotely' bash -c '! git -C "$1" cat-file -e main:tasks/receipts/to-cloud/failedreceipt.md' _ "$T/origin.git"
check 'the conflict writes a pause marker that stops the guarded flush' test -f "$T/state/PAUSED"
check 'the local done task is kept, not rewritten' grep -q '^- Status: done' "$T/repo/tasks/to-local/failedreceipt.md"
check 'the local done receipt is kept, not rewritten' grep -q '^- Result status: done' "$T/repo/tasks/receipts/to-cloud/failedreceipt.md"
H0="$(origin_head)"; run
check 'the next round with PAUSED does not flush the success receipt' unchanged

for field in id path; do
  setup "receipt_identity_$field"; task identity identity $'- Receipt: required\n'
  ( load_runner
    claim_task "$T/repo/tasks/to-local/identity.md" tasks/to-local/identity.md identity >/dev/null 2>&1 || exit 9
    rid=identity; rpath=tasks/to-local/identity.md
    [ "$field" = id ] && rid=other
    [ "$field" = path ] && rpath=tasks/to-local/other.md
    printf '# Receipt: identity\n\n- Task ID: %s\n- Original task: %s\n- Result status: blocked\n' "$rid" "$rpath" >"$T/repo/tasks/receipts/to-cloud/identity.md"
    git -C "$T/repo" add tasks/receipts/to-cloud/identity.md; git -C "$T/repo" commit -qm receipt
    block_task "$T/repo/tasks/to-local/identity.md" tasks/to-local/identity.md identity failure after >/dev/null 2>&1 ); rc=$?
  check "an existing receipt with a conflicting $field is refused" test "$rc" != 0
  check "an existing receipt with a conflicting $field pauses" test -f "$T/state/PAUSED"
done

setup matchingreceipt; task matching matching $'- Receipt: required\n'
( load_runner
  claim_task "$T/repo/tasks/to-local/matching.md" tasks/to-local/matching.md matching >/dev/null 2>&1 || exit 9
  printf '# Receipt: matching\n\n- Task ID: matching\n- Original task: tasks/to-local/matching.md\n- Result status: blocked\n' >"$T/repo/tasks/receipts/to-cloud/matching.md"
  git -C "$T/repo" add tasks/receipts/to-cloud/matching.md; git -C "$T/repo" commit -qm receipt
  cp "$T/repo/tasks/receipts/to-cloud/matching.md" "$T/receipt.before"
  block_task "$T/repo/tasks/to-local/matching.md" tasks/to-local/matching.md matching failure after >/dev/null 2>&1 ); rc=$?
check 'a consistent blocked receipt lets the blocked path finish' test "$rc" = 0
check 'a consistent receipt keeps its exact bytes' cmp "$T/receipt.before" "$T/repo/tasks/receipts/to-cloud/matching.md"

# Review R2: the deployment creates PAUSED between the first check and the lock.
setup pause_race; task pause-race pause-race; H0="$(origin_head)"
( load_runner
  eval "$(declare -f acquire_run_lock | sed '1s/acquire_run_lock/real_acquire_run_lock/')"
  acquire_run_lock() { real_acquire_run_lock || return $?; printf 'deployment\n' >"$PAUSE_FILE"; }
  main >"$T/pause.log" 2>&1 ); rc=$?
check 'PAUSED is re-checked after the run lock is acquired and exits cleanly' test "$rc" = 0
check 'the pause race claims no task' unchanged
check 'the pause race does not invoke the executor' test ! -e "$T/paseo.args"
check 'the pause race releases its own run lock' test ! -e "$T/state/run.lock"

printf 'regressions PASS=%s FAIL=%s (%s, Bash %s)\n' "$PASS" "$FAIL" "$(uname -s)" "$BASH_VERSION"
[ "$FAIL" = 0 ]
