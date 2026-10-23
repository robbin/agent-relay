#!/bin/bash
# Run inside the task checkout. Prints exactly true or false.
#
#   notify-filter.sh BEFORE AFTER FORCED [EVENT]
#   notify-filter.sh --ids BEFORE AFTER FORCED [EVENT]
#
# EVENT selects what the push is checked for:
#   tasks-to-cloud-pending  (default) newly added pending tasks/to-cloud/<ID>.md
#   tasks-to-cloud-receipt  newly added tasks/receipts/to-cloud/<ID>.md
# --ids prints the matching task IDs, one per line, instead of the decision; a
# workflow uses it for the webhook payload. It never changes the decision.
set -eu
MODE=decide
if [ "${1-}" = --ids ]; then MODE=ids; shift; fi
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || { echo 'usage: notify-filter.sh [--ids] BEFORE AFTER FORCED [EVENT]' >&2; exit 1; }
BEFORE=$1 AFTER=$2 FORCED=$3
EVENT=${4:-tasks-to-cloud-pending}
case "$EVENT" in
  tasks-to-cloud-pending) DIR=tasks/to-cloud/ ;;
  tasks-to-cloud-receipt) DIR=tasks/receipts/to-cloud/ ;;
  *) echo "unknown event: $EVENT" >&2; exit 1 ;;
esac
case "$BEFORE:$AFTER" in *[!0-9a-fA-F:]*) echo 'Invalid commit SHA' >&2; exit 1;; esac
ZERO=0000000000000000000000000000000000000000
if [ "$FORCED" = true ] || [ -z "$BEFORE" ] || [ "$BEFORE" = "$ZERO" ] || ! git cat-file -e "${BEFORE}^{commit}" 2>/dev/null; then
  # Conservative wakeup without usable history: the receiver deduplicates. The
  # candidate list is every matching file in AFTER, so a payload can still name
  # them; an empty list is sent along with the same conservative wakeup.
  CONSERVATIVE=true
  CANDIDATES=$(git -c core.quotePath=false ls-tree --name-only "$AFTER" "$DIR")
else
  CONSERVATIVE=false
  # A failure must fail the job, not silently discard a notification.
  CANDIDATES=$(git -c core.quotePath=false diff --no-renames --diff-filter=A --name-only "$BEFORE" "$AFTER" -- "$DIR")
fi

MATCHED=''
while IFS= read -r path; do
  [ -n "$path" ] || continue
  name=${path#"$DIR"}
  case "$name" in */*|README.md) continue;; *.md) ;; *) continue;; esac
  id=${name%.md}
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]{0,95}$ ]] || continue
  if [ "$EVENT" = tasks-to-cloud-pending ]; then
    content=$(git show "${AFTER}:$path")
    status=$(printf '%s\n' "$content" | awk '/^## Result\r?$/ {exit} /^- Status:/ {sub(/^- Status:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit}')
    [ "$status" = pending ] || continue
  fi
  MATCHED="${MATCHED}${id}"$'\n'
done <<< "$CANDIDATES"

if [ "$MODE" = ids ]; then
  printf '%s' "$MATCHED"
  exit 0
fi
if [ "$CONSERVATIVE" = true ]; then echo true; exit 0; fi
case "$MATCHED" in
  '') echo false ;;
  *) echo true ;;
esac
