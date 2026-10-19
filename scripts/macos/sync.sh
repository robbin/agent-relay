#!/bin/bash
# Pull only. Positional configuration is supplied by launchd, never by task files.
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=2'
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
skip() { log "SKIP $*"; exit 0; }
fail() { log "ERROR $*"; exit 1; }
[ "$#" = 2 ] || fail 'usage: sync.sh ABSOLUTE_CHECKOUT EXPECTED_ORIGIN'
REPO=$1
EXPECTED_ORIGIN=$2
case "$REPO" in /*) ;; *) fail 'checkout must be absolute';; esac
[ -d "$REPO" ] || fail 'repository missing'
cd "$REPO"
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] || fail 'not a worktree'
[ "$(pwd -P)" = "$(git rev-parse --show-toplevel)" ] || fail 'checkout must be repository root'
GIT_DIR=$(git rev-parse --absolute-git-dir)
LOCK="$GIT_DIR/agent-relay-git.lock"
mkdir "$LOCK" 2>/dev/null || skip 'Git lock unavailable; check owner or permissions'
cleanup() { rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'sync pid=%s time=%s\n' "$$" "$(date -u '+%FT%TZ')" > "$LOCK/owner"
check_scene() {
  [ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = main ] || skip 'branch is not main'
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
    [ ! -e "$GIT_DIR/$marker" ] || skip 'unfinished Git operation'
  done
  [ -z "$(git status --porcelain)" ] || skip 'working tree or index is dirty'
  [ "$(git remote get-url origin 2>/dev/null || true)" = "$EXPECTED_ORIGIN" ] || fail 'unexpected origin'
}
check_scene
# Transport details are suppressed to keep credentials out of routine logs.
if ! git -c credential.interactive=false -c http.connectTimeout=15 -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 fetch --quiet origin refs/heads/main:refs/remotes/origin/main >/dev/null 2>&1; then
  fail 'fetch failed; check network and credentials manually'
fi
check_scene
[ "$(git rev-list --count origin/main..HEAD)" = 0 ] || skip 'local commits ahead or histories diverged'
BEFORE=$(git rev-parse HEAD)
if ! git merge --ff-only --no-edit origin/main >/dev/null 2>&1; then
  fail 'fast-forward failed; inspect without discarding changes'
fi
AFTER=$(git rev-parse HEAD)
if [ "$BEFORE" = "$AFTER" ]; then
  log "OK unchanged ${AFTER:0:12}"
else
  log "OK updated ${BEFORE:0:12} -> ${AFTER:0:12}"
fi
