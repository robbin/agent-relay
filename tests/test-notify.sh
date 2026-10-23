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

# Receipts are a second event: only tasks/receipts/to-cloud/<ID>.md notifies.
mkdir -p tasks/receipts/to-cloud tasks/receipts/to-local
receipt() {
  cat > "$1" <<EOF
# Receipt: round trip

- Task ID: $(basename "$1" .md)
- Original task: tasks/to-local/$(basename "$1" .md).md
- Result status: ${2:-done}
- Updated: 2026-01-01T11:00:00+00:00
- Summary: Example receipt.
- Artifacts: none
- Next step: Nothing further.
EOF
}
printf '%s\n' 'Receipt notes.' > tasks/receipts/to-cloud/README.md
receipt tasks/receipts/to-cloud/2026-01-01-round-trip.md
receipt tasks/receipts/to-local/2026-01-01-local-receipt.md blocked
git add tasks; git commit -qm receipts
RECEIPT=$(git rev-parse HEAD)
test "$(bash "$ROOT/scripts/notify-filter.sh" "$DELETED" "$RECEIPT" false tasks-to-cloud-receipt)" = true
# The pending-task event ignores receipts, and receipts are not tasks.
test "$(bash "$ROOT/scripts/notify-filter.sh" "$DELETED" "$RECEIPT" false)" = false
test "$(bash "$ROOT/scripts/notify-filter.sh" "$DELETED" "$RECEIPT" false tasks-to-cloud-pending)" = false
test "$(bash "$ROOT/scripts/notify-filter.sh" --ids "$DELETED" "$RECEIPT" false tasks-to-cloud-receipt)" = 2026-01-01-round-trip
# README edits and to-local receipts never notify the cloud agent.
echo 'More notes.' >> tasks/receipts/to-cloud/README.md
git add tasks; git commit -qm receipt-readme
README_ONLY=$(git rev-parse HEAD)
test "$(bash "$ROOT/scripts/notify-filter.sh" "$RECEIPT" "$README_ONLY" false tasks-to-cloud-receipt)" = false
receipt tasks/receipts/to-local/2026-01-02-local-receipt.md done
git add tasks; git commit -qm local-receipt
LOCAL_ONLY=$(git rev-parse HEAD)
test "$(bash "$ROOT/scripts/notify-filter.sh" "$README_ONLY" "$LOCAL_ONLY" false tasks-to-cloud-receipt)" = false
# Forced/zero/missing history stays conservative for receipts too, and the
# candidate list is then every receipt present in AFTER.
test "$(bash "$ROOT/scripts/notify-filter.sh" "$README_ONLY" "$LOCAL_ONLY" true tasks-to-cloud-receipt)" = true
test "$(bash "$ROOT/scripts/notify-filter.sh" 0000000000000000000000000000000000000000 "$LOCAL_ONLY" false tasks-to-cloud-receipt)" = true
test "$(bash "$ROOT/scripts/notify-filter.sh" --ids 0000000000000000000000000000000000000000 "$LOCAL_ONLY" false tasks-to-cloud-receipt)" = 2026-01-01-round-trip
if bash "$ROOT/scripts/notify-filter.sh" "$README_ONLY" "$LOCAL_ONLY" false tasks-to-cloud-bogus >/dev/null 2>&1; then
  echo 'FAIL unknown event accepted'; exit 1
fi
echo 'PASS notify: full push, status/result-only, completed addition, local direction, deletion, forced, zero/missing history; receipts only from receipts/to-cloud, README and to-local ignored, ids and unknown-event rejection'
