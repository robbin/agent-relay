#!/bin/bash
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# No user's Git hooks/config or credentials are used.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_COMMITTER_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
git init --bare -q "$TMP/remote.git"
git init -q -b main "$TMP/seed"
git -C "$TMP/seed" remote add origin "$TMP/remote.git"
echo initial > "$TMP/seed/data"
git -C "$TMP/seed" add data
git -C "$TMP/seed" commit -qm initial
git -C "$TMP/seed" push -qu origin main
git --git-dir="$TMP/remote.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMP/remote.git" "$TMP/local"
run() { bash "$ROOT/scripts/macos/sync.sh" "$TMP/local" "$TMP/remote.git"; }
expect() { case "$1" in *"$2"*) ;; *) echo "FAIL expected $2; got $1"; exit 1;; esac; }
G=$(git -C "$TMP/local" rev-parse --absolute-git-dir)
expect "$(run)" 'OK unchanged'
echo update >> "$TMP/seed/data"
git -C "$TMP/seed" commit -qam update
git -C "$TMP/seed" push -q
expect "$(run)" 'OK updated'
test "$(git -C "$TMP/local" rev-parse HEAD)" = "$(git -C "$TMP/seed" rev-parse HEAD)"
echo dirty >> "$TMP/local/data"
expect "$(run)" 'SKIP working tree'
git -C "$TMP/local" add data
expect "$(run)" 'SKIP working tree'
# Reset is confined to this disposable test repository.
git -C "$TMP/local" reset --hard -q HEAD
mkdir "$G/agent-relay-git.lock"
expect "$(run)" 'SKIP Git lock'
test -d "$G/agent-relay-git.lock"
rmdir "$G/agent-relay-git.lock"
git -C "$TMP/local" checkout -qb other
expect "$(run)" 'SKIP branch'
git -C "$TMP/local" checkout -q main
touch "$G/CHERRY_PICK_HEAD"
expect "$(run)" 'SKIP unfinished'
rm "$G/CHERRY_PICK_HEAD"
echo ahead >> "$TMP/local/data"
git -C "$TMP/local" commit -qam ahead
expect "$(run)" 'SKIP local commits'
echo diverged >> "$TMP/seed/data"
git -C "$TMP/seed" commit -qam diverged
git -C "$TMP/seed" push -q
expect "$(run)" 'SKIP local commits'
if out=$(bash "$ROOT/scripts/macos/sync.sh" "$TMP/local" wrong); then
  echo 'FAIL origin mismatch returned success'; exit 1
fi
expect "$out" 'ERROR unexpected origin'
test ! -d "$G/agent-relay-git.lock"
mv "$TMP/remote.git" "$TMP/offline.git"
if out=$(run); then echo 'FAIL fetch failure returned success'; exit 1; fi
expect "$out" 'ERROR fetch failed'
test ! -d "$G/agent-relay-git.lock"
echo 'PASS sync: fast-forward, unchanged, dirty/staged, lock, branch, unfinished operation, ahead/diverged, wrong origin, fetch failure'
