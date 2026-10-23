#!/bin/bash
# Offline test of the read-only receipt notifier. A fake notification binary
# replaces osascript, everything runs in a temporary checkout and state dir, and
# no launchd job, real notification or network access is involved.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/task checkout"
mkdir -p "$REPO/tasks/receipts/to-local" "$REPO/tasks/receipts/to-cloud" "$TMP/bin"
export HOME="$TMP/home"
export RELAY_STATE_DIR="$TMP/state dir"
export RELAY_LOG="$TMP/logs/receipt-notify.log"
export RELAY_OSASCRIPT_BIN="$TMP/bin/osascript"
export NOTIFY_OUT="$TMP/notified.txt"
export FAIL_FLAG="$TMP/fail-notification"
mkdir -p "$HOME"
cat > "$RELAY_OSASCRIPT_BIN" <<'STUB'
#!/bin/bash
# Records the notification text and fails while FAIL_FLAG exists.
printf '%s\n' "$*" >> "$NOTIFY_OUT"
[ ! -e "$FAIL_FLAG" ]
STUB
chmod +x "$RELAY_OSASCRIPT_BIN"
SEEN="$RELAY_STATE_DIR/receipts-seen.txt"
run() { bash "$ROOT/scripts/macos/receipt-notify.sh" "$REPO"; }
notified() { [ -f "$NOTIFY_OUT" ] && grep -cxF "$1" "$NOTIFY_OUT" || true; }
receipt() {
  cat > "$REPO/tasks/receipts/to-local/$1.md" <<EOF
# Receipt: example round-trip task

- Task ID: $1
- Original task: tasks/to-cloud/$1.md
- Result status: $2
- Updated: 2026-01-01T11:00:00+00:00
- Summary: Result summary for $1.
- Artifacts: none
- Next step: Nothing further.
EOF
}

# 1. First run only records existing receipts; it must not notify.
receipt 2026-01-01-before-install done
cp "$REPO/tasks/receipts/to-local/2026-01-01-before-install.md" "$TMP/receipt copy"
run
test ! -s "$NOTIFY_OUT" || { echo 'FAIL first run notified an existing receipt'; exit 1; }
grep -qxF 2026-01-01-before-install "$SEEN"
cmp -s "$TMP/receipt copy" "$REPO/tasks/receipts/to-local/2026-01-01-before-install.md" \
  || { echo 'FAIL first run modified a receipt'; exit 1; }

# 2. A new receipt is notified once, with its result status and summary.
receipt 2026-01-01-new-receipt done
run
grep -q 'Agent Relay receipt: done' "$NOTIFY_OUT" || { echo 'FAIL notification title/status'; exit 1; }
grep -q '2026-01-01-new-receipt' "$NOTIFY_OUT" || { echo 'FAIL notification body'; exit 1; }
grep -q 'Result summary for 2026-01-01-new-receipt' "$NOTIFY_OUT" || { echo 'FAIL summary missing'; exit 1; }
grep -qxF 2026-01-01-new-receipt "$SEEN"
LINES=$(wc -l < "$NOTIFY_OUT")
test "$LINES" -eq 1 || { echo "FAIL expected one notification, got $LINES"; exit 1; }

# 3. Already-notified receipts are deduplicated on later runs.
run
test "$(wc -l < "$NOTIFY_OUT")" -eq 1 || { echo 'FAIL duplicate notification'; exit 1; }
grep -qxF 2026-01-01-before-install "$SEEN"
test "$(grep -cxF 2026-01-01-new-receipt "$SEEN")" -eq 1 || { echo 'FAIL seen list duplicated an ID'; exit 1; }

# 4. A failed notification is not marked seen and is retried next run.
: > "$FAIL_FLAG"
receipt 2026-01-02-blocked-receipt blocked
if run; then :; else echo 'FAIL run returned non-zero after a notification failure'; exit 1; fi
grep -q '2026-01-02-blocked-receipt' "$NOTIFY_OUT" || { echo 'FAIL notification was not attempted'; exit 1; }
if grep -qxF 2026-01-02-blocked-receipt "$SEEN"; then
  echo 'FAIL failed notification was marked seen'; exit 1
fi
grep -q 'notification failed, retrying next run: 2026-01-02-blocked-receipt' "$RELAY_LOG" \
  || { echo 'FAIL failure was not logged'; exit 1; }
rm -f "$FAIL_FLAG"
run
grep -q 'Agent Relay receipt: blocked' "$NOTIFY_OUT" || { echo 'FAIL retry did not notify'; exit 1; }
grep -qxF 2026-01-02-blocked-receipt "$SEEN" || { echo 'FAIL retry did not mark seen'; exit 1; }
LINES=$(wc -l < "$NOTIFY_OUT")
test "$LINES" -eq 3 || { echo "FAIL expected three notifications after retry, got $LINES"; exit 1; }

# 5. Only tasks/receipts/to-local/<ID>.md is watched: our own to-cloud receipts
#    and a README never notify, and a run leaves the checkout untouched.
printf '%s\n' '# Receipt: ours' '' '- Task ID: 2026-01-03-our-own-receipt' '- Result status: done' \
  > "$REPO/tasks/receipts/to-cloud/2026-01-03-our-own-receipt.md"
printf '%s\n' '# Receipt notes' > "$REPO/tasks/receipts/to-local/README.md"
find "$REPO" -type f | sort > "$TMP/before.txt"
run
test "$(wc -l < "$NOTIFY_OUT")" -eq 3 || { echo 'FAIL to-cloud receipt or README notified'; exit 1; }
if grep -qxF 2026-01-03-our-own-receipt "$SEEN"; then
  echo 'FAIL to-cloud receipt was marked seen'; exit 1
fi
find "$REPO" -type f | sort > "$TMP/after.txt"
cmp -s "$TMP/before.txt" "$TMP/after.txt" || { echo "FAIL run changed the checkout: $(cat "$TMP/after.txt")"; exit 1; }

# 6. A checkout without the receipt directory is a harmless skip.
mkdir -p "$TMP/empty checkout"
bash "$ROOT/scripts/macos/receipt-notify.sh" "$TMP/empty checkout"
grep -q 'receipt directory missing' "$RELAY_LOG" || { echo 'FAIL missing directory not logged'; exit 1; }

# 7. A relative checkout path is rejected; nothing is read relative to the cwd.
if bash "$ROOT/scripts/macos/receipt-notify.sh" relative/checkout >/dev/null 2>&1; then
  echo 'FAIL relative checkout accepted'; exit 1
fi
echo 'PASS receipt-notify: first run marks only, new receipt notified once, dedupe, failed notification retried and not marked seen, to-cloud/README ignored, missing directory skipped, relative path rejected; osascript faked'
