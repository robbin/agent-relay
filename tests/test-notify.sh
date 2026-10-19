#!/bin/bash
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_COMMITTER_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
git init -q -b main "$TMP/repo"
cd "$TMP/repo"
git commit -qm initial --allow-empty
BEFORE=$(git rev-parse HEAD)
mkdir -p tasks/to-cloud tasks/to-local
cp "$ROOT/examples/task.md" tasks/to-cloud/2026-01-01-relay-example.md
git add tasks; git commit -qm task
TASK=$(git rev-parse HEAD)
# Whole-push range includes task added in an earlier commit.
echo note > README.md; git add README.md; git commit -qm docs
AFTER=$(git rev-parse HEAD)
test "$(bash "$ROOT/scripts/notify-filter.sh" "$BEFORE" "$AFTER" false)" = true
# Status-only change must not notify.
awk '{sub(/Status: pending/, "Status: done"); print}' tasks/to-cloud/2026-01-01-relay-example.md > "$TMP/updated"
mv "$TMP/updated" tasks/to-cloud/2026-01-01-relay-example.md
git add tasks; git commit -qm done
DONE=$(git rev-parse HEAD)
test "$(bash "$ROOT/scripts/notify-filter.sh" "$AFTER" "$DONE" false)" = false
# Result-only edits must not notify either.
echo 'Verified result.' >> tasks/to-cloud/2026-01-01-relay-example.md
git add tasks; git commit -qm result
RESULT=$(git rev-parse HEAD)
test "$(bash "$ROOT/scripts/notify-filter.sh" "$DONE" "$RESULT" false)" = false
# A file added then completed within one push is not a pending addition.
test "$(bash "$ROOT/scripts/notify-filter.sh" "$BEFORE" "$DONE" false)" = false
cp "$ROOT/examples/task.md" tasks/to-local/2026-01-01-local-example.md
git add tasks; git commit -qm local
LOCAL=$(git rev-parse HEAD)
test "$(bash "$ROOT/scripts/notify-filter.sh" "$DONE" "$LOCAL" false)" = false
git rm -q tasks/to-cloud/2026-01-01-relay-example.md
git commit -qm remove
DELETED=$(git rev-parse HEAD)
test "$(bash "$ROOT/scripts/notify-filter.sh" "$LOCAL" "$DELETED" false)" = false
test "$(bash "$ROOT/scripts/notify-filter.sh" "$LOCAL" "$DELETED" true)" = true
test "$(bash "$ROOT/scripts/notify-filter.sh" 0000000000000000000000000000000000000000 "$DELETED" false)" = true
test "$(bash "$ROOT/scripts/notify-filter.sh" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$DELETED" false)" = true
echo 'PASS notify: full push, status/result-only, completed addition, local direction, deletion, forced, zero/missing history'
