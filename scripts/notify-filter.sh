#!/bin/bash
# Run inside the task checkout. Prints exactly true or false.
set -eu
[ "$#" = 3 ] || { echo 'usage: notify-filter.sh BEFORE AFTER FORCED' >&2; exit 1; }
BEFORE=$1 AFTER=$2 FORCED=$3
case "$BEFORE:$AFTER" in *[!0-9a-fA-F:]*) echo 'Invalid commit SHA' >&2; exit 1;; esac
if [ "$FORCED" = true ] || [ -z "$BEFORE" ] || [ "$BEFORE" = 0000000000000000000000000000000000000000 ] || ! git cat-file -e "${BEFORE}^{commit}" 2>/dev/null; then
  echo true; exit 0
fi
# A failure must fail the job, not silently discard a notification.
ADDED=$(git -c core.quotePath=false diff --no-renames --diff-filter=A --name-only "$BEFORE" "$AFTER" -- tasks/to-cloud/)
while IFS= read -r path; do
  [ -n "$path" ] || continue
  name=${path#tasks/to-cloud/}
  case "$name" in */*|README.md) continue;; *.md) ;; *) continue;; esac
  id=${name%.md}
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]{0,95}$ ]] || continue
  content=$(git show "${AFTER}:$path")
  status=$(printf '%s\n' "$content" | awk '/^## Result\r?$/ {exit} /^- Status:/ {sub(/^- Status:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit}')
  if [ "$status" = pending ]; then echo true; exit 0; fi
done <<< "$ADDED"
echo false
