#!/bin/bash
# relay-runner.sh — optional local auto-relay executor (launchd: io.agent-relay.runner)
#
# Usage: bash relay-runner.sh ABSOLUTE_CHECKOUT
#
# launchd calls this every 300 seconds. It scans <checkout>/tasks/to-local/ for
# pending tasks whose `- Executor:` field explicitly matches the configured
# executor adapter, claims at most one and dispatches it to that adapter.
#
# Safety guards (see docs/security.md):
#   1. Target directory allowlist: the raw path must not contain `..`; the real
#      path (symlinks resolved) must be inside the checkout, an allowlist entry,
#      or an existing first-level project under RELAY_PROJECTS_ROOT.
#   2. Task body scan: the task text (everything except pure metadata header
#      lines and the Result section) is matched against sensitive patterns
#      (.ssh, private keys, .env, Keychain, upload commands, ...). A hit blocks
#      the task without starting the executor and without echoing the text.
#   3. Output gate (RELAY_GUARD_WAIT=1, default): the executor commits but does
#      not push; the runner waits for it, scans the Result section and changed
#      files for likely secrets, and pushes only when clean. A hit marks the
#      task blocked in a local-only commit, writes the PAUSED marker and pushes
#      nothing. RELAY_GUARD_WAIT=0 restores the fire-and-forget behaviour
#      (the executor pushes itself; layer 3 is then not enforced).
#
# The runner NEVER fetches, pulls, merges, rebases, stashes, resets or force
# pushes. It relies on the separate pull-only sync timer and refuses to act on a
# checkout that is not clean and exactly at origin/main.
#
# The runner never executes task text as shell source. It passes the task scope
# and safety rules to an executor agent as a prompt.
#
# Configuration is by environment variable; every path below has a default but
# nothing machine-specific is embedded. See docs/setup-local-macos.md.
#
# Exit codes: 0 = normal (including nothing to do); 1 = error/skip (logged).

set -uo pipefail

usage() { echo 'usage: bash relay-runner.sh ABSOLUTE_CHECKOUT' >&2; }

CHECKOUT_ARG=${1:-${RELAY_REPO:-}}
case "$CHECKOUT_ARG" in
  /*) ;;
  *) usage; exit 1 ;;
esac
REPO=$(cd "$CHECKOUT_ARG" 2>/dev/null && pwd -P) || { echo "checkout not found: $CHECKOUT_ARG" >&2; exit 1; }

# ---------------------------------------------------------------- configuration
TASKS_SUBDIR=${RELAY_TASKS_SUBDIR:-tasks/to-local}
LOG_FILE=${RELAY_LOG:-$HOME/Library/Logs/agent-relay/runner.log}
SYNC_LOG=${RELAY_SYNC_LOG:-$HOME/Library/Logs/agent-relay/sync.log}
STATE_DIR=${RELAY_STATE_DIR:-$HOME/Library/State/agent-relay/runner}
RUN_LOCK="$STATE_DIR/run.lock"
MARKER_DIR="$STATE_DIR/launched"
TMP_DIR="$STATE_DIR/tmp"
PAUSE_FILE="$STATE_DIR/PAUSED"

GITLOCK_NAME=agent-relay-git.lock
TASKLOCK_DIRNAME=agent-relay-task-locks

# Executor adapter: "paseo" (default) or "command" (a user-supplied wrapper).
EXECUTOR=${RELAY_EXECUTOR:-paseo}
EXECUTOR_BIN=${RELAY_EXECUTOR_BIN:-}
PASEO_CONFIG=${RELAY_PASEO_CONFIG:-$HOME/.paseo/config.json}
PASEO_WORKSPACE=${RELAY_PASEO_WORKSPACE:-}
DEFAULT_PROVIDER=${RELAY_DEFAULT_PROVIDER:-}
DEFAULT_THINKING=${RELAY_DEFAULT_THINKING:-}

# Colon-separated absolute directories the executor may work in (the task
# checkout itself is always allowed). Empty means: checkout only.
WORKSPACE_ALLOWLIST=${RELAY_WORKSPACE_ALLOWLIST:-}
# Optional projects root: any EXISTING first-level directory below it (and its
# subdirectories) is allowed; the root itself is not. Empty disables this.
PROJECTS_ROOT=${RELAY_PROJECTS_ROOT:-}
# 1 = wait for the executor, gate its output, then push (default).
# 0 = legacy asynchronous dispatch; the executor pushes and layer 3 is skipped.
GUARD_WAIT=${RELAY_GUARD_WAIT:-1}

# Optional identity check for origin; empty disables the check.
EXPECTED_ORIGIN=${RELAY_EXPECTED_ORIGIN:-}

MIN_SECONDS_AFTER_SYNC=${RELAY_MIN_SECONDS_AFTER_SYNC:-30}
MAX_SYNC_AGE=${RELAY_MAX_SYNC_AGE:-1500}
PUSH_RETRIES=${RELAY_PUSH_RETRIES:-3}
PUSH_RETRY_DELAY=${RELAY_PUSH_RETRY_DELAY:-10}
LOCK_RECHECK_SECONDS=${RELAY_LOCK_RECHECK_SECONDS:-2}
STALE_TASK_LOCK_SECONDS=${RELAY_STALE_TASK_LOCK_SECONDS:-1800}
MAX_LOG_BYTES=${RELAY_MAX_LOG_BYTES:-10485760}
DRY_RUN=${RELAY_RUNNER_DRY_RUN:-0}

for _v in MIN_SECONDS_AFTER_SYNC MAX_SYNC_AGE PUSH_RETRIES PUSH_RETRY_DELAY \
          LOCK_RECHECK_SECONDS STALE_TASK_LOCK_SECONDS MAX_LOG_BYTES; do
  case "${!_v}" in
    ''|*[!0-9]*) echo "invalid numeric setting $_v=${!_v}" >&2; exit 1 ;;
  esac
done
case "$GUARD_WAIT" in
  0|1) ;;
  *) echo "invalid RELAY_GUARD_WAIT=$GUARD_WAIT (expected 0 or 1)" >&2; exit 1 ;;
esac
case "$EXECUTOR" in
  paseo|command) ;;
  *) echo "unsupported RELAY_EXECUTOR=$EXECUTOR (expected paseo or command)" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- utilities
# Detect stat flavor once; both macOS and GNU coreutils are supported so the
# mocked tests can run on Linux CI.
if stat -f %m / >/dev/null 2>&1; then STAT_FLAVOR=bsd; else STAT_FLAVOR=gnu; fi
file_mtime() {
  if [ "$STAT_FLAVOR" = bsd ]; then stat -f %m "$1" 2>/dev/null || echo 0
  else stat -c %Y "$1" 2>/dev/null || echo 0; fi
}
file_size() {
  if [ "$STAT_FLAVOR" = bsd ]; then stat -f %z "$1" 2>/dev/null || echo 0
  else stat -c %s "$1" 2>/dev/null || echo 0; fi
}

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$MARKER_DIR" "$TMP_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG_FILE" 2>/dev/null || true
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local size
  size=$(file_size "$LOG_FILE")
  if [ "${size:-0}" -gt "$MAX_LOG_BYTES" ]; then
    : >"$LOG_FILE"
    log 'runner log exceeded its size limit; truncated in place'
  fi
}

# First matching header line, English field names, case-insensitive.
# Only "- <name>:" at the start of a line is considered; values are data.
read_field() {
  awk -v key="$2" '
    {
      l = tolower($0)
      if (index(l, "- " tolower(key) ":") == 1) {
        line = $0
        sub(/^-[^:]*:[ \t]*/, "", line)
        sub(/[ \t\r]+$/, "", line)
        print line
        exit
      }
    }
  ' "$1" 2>/dev/null
}

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_pending() { [ "$(lc "$1")" = pending ]; }
matches_executor() { [ -n "$1" ] && [ "$(lc "$1")" = "$(lc "$EXECUTOR")" ]; }

resolve_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# ---------------------------------------------------------------- guard 1: target directory
# Allow: the task checkout (or a directory inside it), each allowlist entry, and
# existing first-level projects under PROJECTS_ROOT. Comparison uses real paths
# (cd + pwd -P) on both sides, so symlinks cannot escape. The raw value must not
# contain a `..` segment. Sets DIR_ERR on failure.
dir_allowed() {
  local raw=$1 candidate repo_real entry base rel first
  DIR_ERR=''
  case "/$raw/" in
    */../*) DIR_ERR="Target directory contains a '..' segment: $raw"; return 1 ;;
  esac
  candidate=$(resolve_dir "$raw") || { DIR_ERR="Target directory cannot be resolved: $raw"; return 1; }
  repo_real=$(resolve_dir "$REPO") || { DIR_ERR='checkout cannot be resolved'; return 1; }
  case "$candidate/" in
    "$repo_real"/.git/*) DIR_ERR="Target directory is inside the checkout's .git directory: $raw"; return 1 ;;
  esac
  if [ "$candidate" = "$repo_real" ]; then return 0; fi
  case "$candidate" in "$repo_real"/*) return 0 ;; esac
  local IFS=:
  for entry in $WORKSPACE_ALLOWLIST; do
    [ -n "$entry" ] || continue
    base=$(resolve_dir "$entry") || continue
    if [ "$candidate" = "$base" ]; then return 0; fi
    case "$candidate" in "$base"/*) return 0 ;; esac
  done
  if [ -n "$PROJECTS_ROOT" ] && base=$(resolve_dir "$PROJECTS_ROOT"); then
    case "$candidate" in
      "$base"/*)
        rel=${candidate#"$base"/}
        first=${rel%%/*}
        if [ -n "$first" ] && [ "$(resolve_dir "$base/$first" || true)" = "$base/$first" ]; then
          return 0
        fi
        ;;
    esac
  fi
  DIR_ERR="Target directory is outside the configured allowlist: $raw (real path $candidate)"
  return 1
}

# ---------------------------------------------------------------- guard 2: task body scan
# Extended regexes matched case-insensitively against the task body. Token
# matching is deliberately narrow (access/auth/api/refresh/bearer/bot token, or
# token= / token:) so ordinary words such as "token count" do not trigger.
GUARD_SENSITIVE_PATTERNS=(
  '\.ssh'
  'id_rsa|id_ed25519|id_ecdsa'
  'private[ _-]?key'
  'auth\.json'
  'keychain|security +find-'
  '(^|[^a-z0-9])\.env([^a-z0-9]|$)'
  'secrets?'
  'credentials?'
  '(access|auth|api|refresh|bearer|bot)[_ -]?token|token[[:space:]]*[=:]'
  'password|passwd'
  'api[_-]?key'
  '\.aws'
  '\.gnupg'
  'cookies|login data'
  '(scp|rsync) .*:'
  '(curl|wget).*(-d|--data|-F|--form|-T|--upload-file)'
  '(^|[^a-z])nc( |$)'
  'base64.*(curl|wget|nc|scp)'
  'pastebin|transfer\.sh|0x0\.st|ix\.io'
)
# Non-ASCII patterns (matched without -i to avoid locale differences).
GUARD_SENSITIVE_PATTERNS_UTF8=(
  '密码'
  '私钥'
  '密钥'
  '凭据'
)

# Only metadata header lines whose values the runner validates itself are
# skipped (Task ID, Status, Executor, Role, Target directory). Everything else,
# including "- Task:", "- Constraints:", "- Inputs:" and any pre-filled Result
# text, is scanned: a pending task's Result should be empty.
guard_scan() { # $1=task file; on a hit sets GUARD_SCAN_HITS (pattern names only)
  local file=$1 body pat hits=''
  GUARD_SCAN_HITS=''
  body=$(mktemp "$TMP_DIR/scan.XXXXXX") || { GUARD_SCAN_HITS='cannot create temp file'; return 1; }
  awk '
    { low = tolower($0) }
    low ~ /^-[ \t]*(task id|status|executor|role|target directory)[ \t]*:/ { next }
    # Notes appended by the runner itself (so a fixed task can be recovered).
    /^- Runner: (dispatch|output gate) blocked (this task )?at [0-9TZ:-]+: / { next }
    /^- Needed: (fix the cause above|nothing was pushed)\. / { next }
    { print }
  ' "$file" >"$body" 2>/dev/null || { rm -f "$body"; GUARD_SCAN_HITS='cannot read the task body'; return 1; }
  for pat in "${GUARD_SENSITIVE_PATTERNS[@]}"; do
    if LC_ALL=C grep -Eqi -- "$pat" "$body" 2>/dev/null; then hits="${hits}${hits:+; }${pat}"; fi
  done
  for pat in "${GUARD_SENSITIVE_PATTERNS_UTF8[@]}"; do
    if grep -Fq -- "$pat" "$body" 2>/dev/null; then hits="${hits}${hits:+; }${pat}"; fi
  done
  rm -f "$body"
  if [ -n "$hits" ]; then GUARD_SCAN_HITS=$hits; return 1; fi
  return 0
}

# ---------------------------------------------------------------- guard 3: output gate
# Case-sensitive extended regexes for likely secrets. 40-char Git SHAs are below
# the {48,} hex threshold on purpose.
GUARD_SECRET_PATTERNS=(
  'sk-[A-Za-z0-9_-]{20,}'
  'ghp_[A-Za-z0-9]{30,}'
  'gh[ousr]_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'xox[abpr]-[A-Za-z0-9-]{10,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '[0-9a-fA-F]{48,}'
  '[A-Za-z0-9+/]{60,}={0,2}'
  'Bearer +[A-Za-z0-9._~+/-]{20,}'
  "[A-Za-z0-9_]*(KEY|TOKEN|SECRET)[A-Za-z0-9_]* *[=:] *['\"]?[A-Za-z0-9/+._-]{12,}"
)

join_unique() { printf '%s\n' "$1" | awk 'NF && !seen[$0]++' | tr '\n' ';' | sed -e 's/;$//'; }

# Scans exactly what would be pushed: every commit in origin/main..HEAD (commit
# messages and all added lines, including binary content via --text and blobs
# that a later commit deleted). Uncommitted leftovers are never pushed.
# Returns 0 = clean, 1 = likely secret found, 2 = the check itself failed.
# Any non-zero result means: do not push. Only pattern and file names are
# recorded, never the matched values. Sets GUARD_SCANNED_SHA.
guard_output() {
  local dir pat patterns='' files=''
  GUARD_OUT_PATTERNS=''; GUARD_OUT_FILES=''; GUARD_OUT_ERR=''; GUARD_SCANNED_SHA=''
  GUARD_SCANNED_SHA=$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null) \
    || { GUARD_OUT_ERR='cannot resolve HEAD'; return 2; }
  dir=$(mktemp -d "$TMP_DIR/guard.XXXXXX") || { GUARD_OUT_ERR='mktemp -d failed'; return 2; }
  if ! git -C "$REPO" -c core.quotePath=false log -p -m -U0 --text --no-renames --no-color \
       --format='@@RELAY-COMMIT@@%n%w(0,4,4)%B' "origin/main..$GUARD_SCANNED_SHA" >"$dir/log" 2>/dev/null; then
    GUARD_OUT_ERR='cannot read the commits to push'; rm -rf "$dir"; return 2
  fi
  # Strip NUL bytes so binary content stays scannable with BSD awk/grep (macOS).
  LC_ALL=C tr -d '\000' <"$dir/log" >"$dir/log.txt" \
    || { GUARD_OUT_ERR='cannot prepare the commits to push'; rm -rf "$dir"; return 2; }
  # Emit "<label>\t<added line>" for commit messages and added diff lines.
  awk '
    /^@@RELAY-COMMIT@@$/ { label = "commit message"; inmsg = 1; hdr = 0; next }
    /^diff --git / { inmsg = 0; hdr = 1; label = "?"; next }
    inmsg { print label "\t" $0; next }
    hdr && /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); label = f; next }
    /^@@ / { hdr = 0; next }
    hdr { next }
    /^\+/ { print label "\t" substr($0, 2) }
  ' "$dir/log.txt" >"$dir/added" 2>/dev/null || { GUARD_OUT_ERR='cannot parse the commits to push'; rm -rf "$dir"; return 2; }
  for pat in "${GUARD_SECRET_PATTERNS[@]}"; do
    if cut -f2- "$dir/added" | LC_ALL=C grep -aEq -- "$pat" 2>/dev/null; then
      patterns="${patterns}${pat}"$'\n'
      files="${files}$(LC_ALL=C grep -aE -- "$pat" "$dir/added" 2>/dev/null | cut -f1 | sort -u)"$'\n'
    fi
  done
  rm -rf "$dir"
  if [ -n "$patterns" ]; then
    GUARD_OUT_PATTERNS=$(join_unique "$patterns")
    GUARD_OUT_FILES=$(join_unique "$files")
    [ -n "$GUARD_OUT_FILES" ] || GUARD_OUT_FILES='?'
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- lock helpers
# The run lock is private to this script. Only a provably dead pid is reclaimed;
# Git and task locks are never removed by the runner.
acquire_run_lock() {
  if mkdir "$RUN_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" >"$RUN_LOCK/pid"
    return 0
  fi
  local pid=''
  [ -f "$RUN_LOCK/pid" ] && pid=$(cat "$RUN_LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "skip: another relay-runner is running (pid $pid)"
    return 1
  fi
  sleep "$LOCK_RECHECK_SECONDS"
  if [ -f "$RUN_LOCK/pid" ]; then
    pid=$(cat "$RUN_LOCK/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "skip: another relay-runner is running (pid $pid)"
      return 1
    fi
  fi
  rm -f "$RUN_LOCK/pid"
  rmdir "$RUN_LOCK" 2>/dev/null || { log "skip: cannot clear stale run lock $RUN_LOCK"; return 1; }
  log "note: reclaimed a stale run lock (old pid ${pid:-unknown} is gone)"
  mkdir "$RUN_LOCK" 2>/dev/null || { log 'skip: cannot acquire run lock'; return 1; }
  printf '%s\n' "$$" >"$RUN_LOCK/pid"
  return 0
}

release_run_lock() {
  [ -f "$RUN_LOCK/pid" ] || return 0
  [ "$(cat "$RUN_LOCK/pid" 2>/dev/null || true)" = "$$" ] || return 0
  rm -f "$RUN_LOCK/pid"
  rmdir "$RUN_LOCK" 2>/dev/null || true
}

GIT_LOCK=''
acquire_git_lock() {
  GIT_LOCK="$GIT_DIR/$GITLOCK_NAME"
  mkdir "$GIT_LOCK" 2>/dev/null || return 1
  printf 'runner pid=%s time=%s\n' "$$" "$(now_utc)" >"$GIT_LOCK/owner" 2>/dev/null || true
  return 0
}

release_git_lock() {
  [ -n "$GIT_LOCK" ] || return 0
  [ -f "$GIT_LOCK/owner" ] || return 0
  grep -q "pid=$$ " "$GIT_LOCK/owner" 2>/dev/null || return 0
  rm -f "$GIT_LOCK/owner"
  rmdir "$GIT_LOCK" 2>/dev/null || true
  GIT_LOCK=''
}

# ---------------------------------------------------------------- preconditions
check_sync_timing() {
  local age
  if [ ! -f "$SYNC_LOG" ]; then
    log "skip: sync log not found ($SYNC_LOG); cannot confirm the checkout is fresh"
    return 1
  fi
  age=$(( $(date +%s) - $(file_mtime "$SYNC_LOG") ))
  if [ "$age" -lt "$MIN_SECONDS_AFTER_SYNC" ]; then
    log "skip: last sync was ${age}s ago (< ${MIN_SECONDS_AFTER_SYNC}s); yield to the sync timer"
    return 1
  fi
  if [ "$age" -gt "$MAX_SYNC_AGE" ]; then
    log "skip: sync log is ${age}s old (> ${MAX_SYNC_AGE}s); refusing to act on stale data"
    return 1
  fi
  log "timing ok: last sync ${age}s ago"
  return 0
}

repo_ready() {
  local branch marker head origin
  [ "$(git -C "$REPO" rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
    || { log "error: $REPO is not a Git worktree"; return 1; }
  [ "$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)" = "$REPO" ] \
    || { log "error: $REPO must be the repository root"; return 1; }

  if [ -n "$EXPECTED_ORIGIN" ]; then
    [ "$(git -C "$REPO" remote get-url origin 2>/dev/null || true)" = "$EXPECTED_ORIGIN" ] \
      || { log "error: origin does not match RELAY_EXPECTED_ORIGIN"; return 1; }
  fi

  branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$branch" = main ] || { log "skip: branch is ${branch:-unknown}, not main"; return 1; }

  GIT_DIR=$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null) \
    || { log "error: cannot resolve the Git directory"; return 1; }
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
    [ ! -e "$GIT_DIR/$marker" ] || { log "skip: unfinished Git operation ($marker)"; return 1; }
  done

  [ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] \
    || { log 'skip: working tree or index is dirty (left for sync or the user; no stash/reset)'; return 1; }

  git -C "$REPO" var GIT_COMMITTER_IDENT >/dev/null 2>&1 \
    || { log 'skip: no Git committer identity in this checkout; configure user.name/user.email first'; return 1; }

  head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)
  origin=$(git -C "$REPO" rev-parse origin/main 2>/dev/null || true)
  [ -n "$origin" ] || { log 'skip: origin/main is unavailable; wait for the sync fetch'; return 1; }
  [ "$head" = "$origin" ] \
    || { log "skip: HEAD ($head) differs from origin/main ($origin); wait for sync to fast-forward"; return 1; }

  log "checkout ok: main, clean, at origin/main (${head:0:12})"
  return 0
}

# ---------------------------------------------------------------- Git writes
# Commit only the named task file. Never stages anything else, never force pushes.
# The caller must hold the shared Git lock.
git_commit_push() { # $1=repo-relative path $2=message
  local rel=$1 msg=$2 i staged
  git -C "$REPO" add -- "$rel" || { log "error: git add failed ($rel)"; return 1; }
  staged=$(git -C "$REPO" diff --cached --name-only 2>/dev/null)
  if [ "$staged" != "$rel" ]; then
    log "error: refusing to commit unexpected staged paths: ${staged:-<none>}"
    git -C "$REPO" restore --staged -- "$rel" >/dev/null 2>&1 || true
    return 1
  fi
  if git -C "$REPO" diff --cached --quiet -- "$rel"; then
    log "note: $rel has no staged change; skipping commit"
    return 0
  fi
  git -C "$REPO" commit -q -m "$msg" || { log 'error: git commit failed'; return 1; }
  i=1
  while [ "$i" -le "$PUSH_RETRIES" ]; do
    if git -C "$REPO" push origin HEAD:main >>"$LOG_FILE" 2>&1; then
      return 0
    fi
    log "push failed (attempt $i/$PUSH_RETRIES)"
    [ "$i" -lt "$PUSH_RETRIES" ] && sleep "$PUSH_RETRY_DELAY"
    i=$((i + 1))
  done
  return 1
}

claim_task() { # $1=file $2=relative path $3=task ID
  local file=$1 rel=$2 id=$3 ts tmp rc=0
  ts=$(now_utc)
  tmp=$(mktemp "$TMP_DIR/tmp.XXXXXX") || { log 'error: mktemp failed'; return 1; }

  awk -v ts="$ts" '
    BEGIN { status_done = 0; updated_done = 0 }
    {
      low = tolower($0)
      if (!status_done && low ~ /^-[ \t]*status[ \t]*:/) {
        print "- Status: accepted"; status_done = 1; next
      }
      if (!updated_done && low ~ /^-[ \t]*updated[ \t]*:/) {
        print "- Updated: " ts; updated_done = 1; next
      }
      print
    }
  ' "$file" >"$tmp" || { log 'error: cannot build claim file'; rm -f "$tmp"; return 1; }

  grep -q '^- Status: accepted$' "$tmp" \
    || { log 'error: generated claim file has no accepted status line; aborting'; rm -f "$tmp"; return 1; }

  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would claim $rel as accepted and push it (no file or Git change made)"
    rm -f "$tmp"
    return 0
  fi

  if ! acquire_git_lock; then
    log "skip: shared Git lock is held ($GIT_DIR/$GITLOCK_NAME); retry next round"
    rm -f "$tmp"
    return 1
  fi

  if ! mv "$tmp" "$file"; then
    log 'error: cannot replace the task file'
    rm -f "$tmp"
    release_git_lock
    return 1
  fi

  if git_commit_push "$rel" "Claim task $id: status accepted"; then
    log "claimed and pushed: $rel (accepted, $ts)"
  else
    log "error: claim commit/push failed; the local task file is accepted but not recorded remotely. Inspect and reconcile before retrying."
    rc=1
  fi
  release_git_lock
  return "$rc"
}

block_task() { # $1=file $2=relative path $3=task ID $4=reason
  local file=$1 rel=$2 id=$3 reason=$4 ts tmp rc=0
  ts=$(now_utc)
  tmp=$(mktemp "$TMP_DIR/tmp.XXXXXX") || { log 'error: mktemp failed'; return 1; }

  awk -v ts="$ts" -v reason="$reason" '
    BEGIN { status_done = 0; updated_done = 0 }
    {
      low = tolower($0)
      if (!status_done && low ~ /^-[ \t]*status[ \t]*:/) {
        print "- Status: blocked"; status_done = 1; next
      }
      if (!updated_done && low ~ /^-[ \t]*updated[ \t]*:/) {
        print "- Updated: " ts; updated_done = 1; next
      }
      print
    }
    END {
      print ""
      print "- Runner: dispatch blocked at " ts ": " reason
      print "- Needed: fix the cause above, then explicitly recover this task. The runner never retries or replaces blocked tasks."
    }
  ' "$file" >"$tmp" || { log 'error: cannot build blocked file'; rm -f "$tmp"; return 1; }

  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would mark $rel blocked: $reason"
    rm -f "$tmp"
    return 0
  fi

  if ! acquire_git_lock; then
    log "error: Git lock unavailable; cannot record blocked state for $id now"
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$file"; then
    log 'error: cannot replace the task file with its blocked state'
    rm -f "$tmp"
    release_git_lock
    return 1
  fi
  if git_commit_push "$rel" "Task $id: dispatch blocked"; then
    log "recorded blocked: $rel ($reason)"
  else
    log "error: failed to push the blocked state for $id"
    rc=1
  fi
  release_git_lock
  return "$rc"
}

# Output gate passed: push the executor's local commits under the shared lock.
push_guarded() {
  local i=1 tries=0
  while ! acquire_git_lock; do
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      log "error: shared Git lock still held ($GIT_DIR/$GITLOCK_NAME); local commits kept, not pushed"
      return 1
    fi
    sleep "$LOCK_RECHECK_SECONDS"
  done
  if [ "$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" != "$GUARD_SCANNED_SHA" ]; then
    log 'error: HEAD moved after the output gate scan; refusing to push unscanned commits'
    release_git_lock
    return 1
  fi
  while [ "$i" -le "$PUSH_RETRIES" ]; do
    if git -C "$REPO" push origin "$GUARD_SCANNED_SHA:refs/heads/main" >>"$LOG_FILE" 2>&1; then
      release_git_lock
      return 0
    fi
    log "guarded push failed (attempt $i/$PUSH_RETRIES)"
    [ "$i" -lt "$PUSH_RETRIES" ] && sleep "$PUSH_RETRY_DELAY"
    i=$((i + 1))
  done
  release_git_lock
  return 1
}

# Output gate hit: mark blocked in a LOCAL-ONLY commit. Never pushes.
block_local() { # $1=file $2=relative path $3=task ID $4=reason (pattern/file names only)
  local file=$1 rel=$2 id=$3 reason=$4 ts tmp
  ts=$(now_utc)
  tmp=$(mktemp "$TMP_DIR/tmp.XXXXXX") || { log 'error: mktemp failed'; return 1; }
  awk -v ts="$ts" -v reason="$reason" '
    BEGIN { status_done = 0; updated_done = 0 }
    {
      low = tolower($0)
      if (!status_done && low ~ /^-[ \t]*status[ \t]*:/) { print "- Status: blocked"; status_done = 1; next }
      if (!updated_done && low ~ /^-[ \t]*updated[ \t]*:/) { print "- Updated: " ts; updated_done = 1; next }
      print
    }
    END {
      print ""
      print "- Runner: output gate blocked this task at " ts ": " reason
      print "- Needed: nothing was pushed. Inspect and clean the unpushed local commits (git log origin/main..HEAD), then remove the PAUSED marker to resume."
    }
  ' "$file" >"$tmp" || { rm -f "$tmp"; log 'error: cannot build blocked file'; return 1; }
  if ! acquire_git_lock; then
    rm -f "$tmp"; log 'error: Git lock unavailable; blocked state not recorded locally'; return 1
  fi
  mv "$tmp" "$file" || { rm -f "$tmp"; release_git_lock; log 'error: cannot replace the task file'; return 1; }
  git -C "$REPO" add -- "$rel" || { release_git_lock; log "error: git add failed ($rel)"; return 1; }
  if ! git -C "$REPO" diff --cached --quiet -- "$rel"; then
    git -C "$REPO" commit -q -m "Task $id: output gate blocked (not pushed)" -- "$rel" \
      || { release_git_lock; log 'error: local blocked commit failed'; return 1; }
  fi
  release_git_lock
  log "recorded blocked locally (not pushed): $rel"
  return 0
}

write_pause() { # $1=reason (no secret values)
  {
    printf 'Paused at: %s\n' "$(now_utc)"
    printf 'Reason: %s\n' "$1"
    printf 'Recovery: inspect git log/diff origin/main..HEAD in %s, clean the unpushed commits, then delete %s.\n' "$REPO" "$PAUSE_FILE"
  } >"$PAUSE_FILE" 2>/dev/null && { log "pause marker written: $PAUSE_FILE"; return 0; }
  log "error: could not write the pause marker $PAUSE_FILE"
  return 1
}

# With the output gate on, the executor's own pushes are disabled (best effort):
# its Git processes inherit an invalid origin pushurl via GIT_CONFIG_* env, and
# the checkout gets the same pushurl in its local config while the executor
# runs (only when no pushurl is configured; removed again afterwards). The
# runner's own guarded push names the fetch URL explicitly.
GUARD_PUSHURL=relay-guard-push-disabled://
block_executor_push() {
  [ "$GUARD_WAIT" = 1 ] || return 0
  [ -z "$(git -C "$REPO" config --get-all remote.origin.pushurl 2>/dev/null)" ] || return 0
  git -C "$REPO" config remote.origin.pushurl "$GUARD_PUSHURL" 2>/dev/null \
    || log 'warning: could not disable executor pushes in the checkout config'
}
unblock_executor_push() {
  if [ "$(git -C "$REPO" config --get-all remote.origin.pushurl 2>/dev/null)" = "$GUARD_PUSHURL" ]; then
    git -C "$REPO" config --unset remote.origin.pushurl 2>/dev/null || true
  fi
}
executor_env() {
  if [ "$GUARD_WAIT" = 1 ]; then
    printf '%s\n' GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl \
      GIT_CONFIG_VALUE_0=relay-guard-push-disabled://
  fi
}

# ---------------------------------------------------------------- executor config
# Read only daemon.agentProfiles from a Paseo config. A missing role is an error;
# the runner never substitutes a different role or provider.
role_lookup() { # $1=role name
  local role=$1 out rc
  ROLE_ERR=''
  ROLE_SOURCE=preset
  ROLE_NAME=$role
  ROLE_PROVIDER=''; ROLE_MODEL=''; ROLE_MODE=''; ROLE_THINKING=''
  ROLE_FEATURE_KEYS=''; ROLE_NOTES=''

  if ! command -v python3 >/dev/null 2>&1; then
    ROLE_ERR='python3 is required to read Paseo role presets'
    return 1
  fi

  out=$(python3 - "$PASEO_CONFIG" "$role" <<'PY'
import json, sys
path, role = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
except FileNotFoundError:
    sys.exit(5)
except Exception:
    sys.exit(6)
profiles = data.get('daemon', {}).get('agentProfiles')
if not isinstance(profiles, list):
    sys.exit(7)
match = None
for item in profiles:
    if isinstance(item, dict) and item.get('name') == role:
        match = item
        break
if match is None:
    sys.exit(4)
def s(v):
    return '-' if v is None or v == '' else str(v)
feat = match.get('featureValues')
keys = ','.join(sorted(feat.keys())) if isinstance(feat, dict) else ''
sys.stdout.write('\t'.join([s(match.get('provider')), s(match.get('model')),
                            s(match.get('modeId')), s(match.get('thinkingOptionId')),
                            keys]) + '\n' + s(match.get('notes')))
PY
)
  rc=$?
  case "$rc" in
    0) ;;
    4) ROLE_ERR="role '$role' is not in daemon.agentProfiles of $PASEO_CONFIG (exact name match)"; return 1 ;;
    5) ROLE_ERR="role config not found: $PASEO_CONFIG"; return 1 ;;
    6) ROLE_ERR="cannot parse $PASEO_CONFIG as JSON"; return 1 ;;
    7) ROLE_ERR="$PASEO_CONFIG has no daemon.agentProfiles array"; return 1 ;;
    *) ROLE_ERR="role lookup failed (python3 exit $rc)"; return 1 ;;
  esac

  local head1
  head1=$(printf '%s\n' "$out" | head -n 1)
  ROLE_NOTES=$(printf '%s\n' "$out" | tail -n +2)
  IFS=$'\t' read -r ROLE_PROVIDER ROLE_MODEL ROLE_MODE ROLE_THINKING ROLE_FEATURE_KEYS <<<"$head1"
  [ "$ROLE_PROVIDER" = '-' ] && ROLE_PROVIDER=''
  [ "$ROLE_MODEL" = '-' ] && ROLE_MODEL=''
  [ "$ROLE_MODE" = '-' ] && ROLE_MODE=''
  [ "$ROLE_THINKING" = '-' ] && ROLE_THINKING=''
  [ "$ROLE_FEATURE_KEYS" = '-' ] && ROLE_FEATURE_KEYS=''
  [ -n "$ROLE_NOTES" ] && [ "$ROLE_NOTES" = '-' ] && ROLE_NOTES=''

  if [ -z "$ROLE_PROVIDER" ]; then
    ROLE_ERR="role '$role' has no provider configured"
    return 1
  fi
  return 0
}

builtin_default_role() {
  ROLE_SOURCE=builtin
  ROLE_NAME=default
  if [ -n "$DEFAULT_PROVIDER" ]; then
    case "$DEFAULT_PROVIDER" in
      */*) ROLE_PROVIDER=${DEFAULT_PROVIDER%%/*}; ROLE_MODEL=${DEFAULT_PROVIDER#*/} ;;
      *) ROLE_PROVIDER=$DEFAULT_PROVIDER; ROLE_MODEL='' ;;
    esac
  else
    ROLE_PROVIDER=''; ROLE_MODEL=''
  fi
  ROLE_MODE=''
  ROLE_THINKING=$DEFAULT_THINKING
  ROLE_FEATURE_KEYS=''
  ROLE_NOTES=''
  return 0
}

provider_available() { # $1=provider
  local provider=$1 out rc lines
  PROVIDER_ERR=''
  out=$("$EXECUTOR_BIN_PATH" provider ls 2>>"$LOG_FILE")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    PROVIDER_ERR="executor 'provider ls' failed (exit $rc); cannot verify provider availability"
    return 1
  fi
  lines=$(printf '%s\n' "$out" | awk -v p="$provider" '$1 == p' || true)
  if [ -z "$lines" ]; then
    PROVIDER_ERR="provider '$provider' is not listed by the executor"
    return 1
  fi
  if printf '%s\n' "$lines" | grep -Eqi 'disabled|unavailable|not[ _-]?enabled|missing'; then
    PROVIDER_ERR="provider '$provider' is marked unavailable"
    return 1
  fi
  if ! printf '%s\n' "$lines" | grep -Eqi 'available|enabled'; then
    log "note: executor provider list has no available/enabled wording; accepting literal match for $provider"
  fi
  return 0
}

resolve_executor_bin() {
  EXECUTOR_BIN_PATH=''
  EXECUTOR_ERR=''
  if [ -n "$EXECUTOR_BIN" ]; then
    case "$EXECUTOR_BIN" in
      */*) [ -x "$EXECUTOR_BIN" ] && EXECUTOR_BIN_PATH=$EXECUTOR_BIN ;;
      *) EXECUTOR_BIN_PATH=$(command -v "$EXECUTOR_BIN" 2>/dev/null || true) ;;
    esac
  elif [ "$EXECUTOR" = paseo ]; then
    EXECUTOR_BIN_PATH=$(command -v paseo 2>/dev/null || true)
  fi
  [ -n "$EXECUTOR_BIN_PATH" ] || {
    EXECUTOR_ERR="executor binary not found (set RELAY_EXECUTOR_BIN for adapter '$EXECUTOR')"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------- dispatch
build_prompt() { # $1=task ID $2=relative path $3=task lock path
  local id=$1 rel=$2 tasklock=$3 notes allowlist push_rule finish_verb
  if [ "$GUARD_WAIT" = 1 ]; then
    push_rule='Do NOT git push: the runner scans your output and pushes it only if clean.'
    finish_verb='commit (do not push)'
  else
    push_rule='Push your commit to origin main when done.'
    finish_verb='commit/push'
  fi
  notes=$ROLE_NOTES
  [ -n "$notes" ] || notes='No extra role notes. Act as a careful general-purpose executor.'
  allowlist=$WORKSPACE_ALLOWLIST
  [ -n "$allowlist" ] || allowlist='none configured (the task checkout only)'
  [ -z "$PROJECTS_ROOT" ] || allowlist="$allowlist; existing projects directly under $PROJECTS_ROOT"

  cat <<EOF
You were dispatched automatically by the local Agent Relay runner for task $id.
Task file: $rel in the task checkout $REPO
Protocol (read it first): $REPO/tasks/README.md

Role notes:
<role-notes>
$notes
</role-notes>

Hard requirements:
1. Read the protocol and the task file, then work only within the task's stated
   scope. Do not create new tasks and do not widen permissions.
2. Allowed locations: the task checkout and these configured directories:
   $allowlist
   If the task needs any other path, set the task status to blocked and state
   why. Never expand the scope on your own.
3. High-risk actions are prepare-only: publishing, deleting files or data,
   deploying, changing permissions (chmod/chown), opening ports or firewall
   rules, and external messages. Put the prepared commands or drafts in Result
   and wait for explicit user authorization.
4. Write the outcome only in the task file's "## Result" section. Change
   "- Status:" from accepted to done or blocked and update "- Updated:" with an
   ISO 8601 timestamp including a timezone. blocked must include the reason and
   what the user must do; never present blocked as completion.
5. Commit only this task file and material the task explicitly authorizes.
   Never use git add -A, force-push, rebase, reset or stash; never rewrite other
   commits. Do not modify tasks/README.md or other task files.
   $push_rule
6. Before Git writes, take the shared lock: run 'git rev-parse --absolute-git-dir'
   in $REPO, then 'mkdir <git-dir>/$GITLOCK_NAME'. If that fails, wait for the
   next opportunity; never delete another process's lock. Release only your own
   lock after committing.
7. Do not modify, load or install credential-related launchd jobs, do not read
   the Keychain, and never print or persist secrets.
8. Release your task lock when finished: 'rmdir $tasklock' — only this lock.
9. If you cannot finish, set blocked with the reason and $finish_verb it. Do not
   leave a half-done state or silently repeat an action with side effects.
EOF
}

launch_paseo() { # $1=task ID $2=cwd $3=prompt
  local id=$1 cwd=$2 prompt=$3 provider_arg desc
  local -a args

  if [ -n "$ROLE_MODEL" ]; then provider_arg="$ROLE_PROVIDER/$ROLE_MODEL"
  else provider_arg="$ROLE_PROVIDER"; fi

  if [ -n "$ROLE_FEATURE_KEYS" ]; then
    log "note: role '$ROLE_NAME' featureValues are not applied by the Paseo CLI (keys=$ROLE_FEATURE_KEYS); using provider defaults"
  fi

  # The prompt is positional and must remain last.
  # With the output gate on, wait for the agent (no --no-wait) so the runner can
  # inspect its local commits before anything is pushed.
  if [ "$GUARD_WAIT" = 1 ]; then
    args=(run); desc=run
  else
    args=(run --no-wait); desc="run --no-wait"
  fi
  if [ -n "$PASEO_WORKSPACE" ]; then
    args+=(--workspace "$PASEO_WORKSPACE"); desc+=" --workspace $PASEO_WORKSPACE"
  fi
  if [ -n "$cwd" ]; then args+=(--cwd "$cwd"); desc+=" --cwd $cwd"; fi
  if [ -n "$provider_arg" ]; then args+=(--provider "$provider_arg"); desc+=" --provider $provider_arg"; fi
  if [ -n "$ROLE_MODE" ]; then args+=(--mode "$ROLE_MODE"); desc+=" --mode $ROLE_MODE"; fi
  if [ -n "$ROLE_THINKING" ]; then args+=(--thinking "$ROLE_THINKING"); desc+=" --thinking $ROLE_THINKING"; fi
  args+=(--title "$id" --label source=relay-runner --label "task=$id" --label "role=$ROLE_NAME")
  args+=("$prompt")
  desc+=" --title $id --label source=relay-runner --label task=$id --label role=$ROLE_NAME <prompt>"

  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would run: $EXECUTOR_BIN_PATH $desc"
    return 0
  fi

  log "dispatch: $EXECUTOR_BIN_PATH $desc"
  local rc
  local _e
  local -a xenv=()
  while IFS= read -r _e; do [ -n "$_e" ] && xenv+=("$_e"); done < <(executor_env)
  if env ${xenv[@]+"${xenv[@]}"} "$EXECUTOR_BIN_PATH" "${args[@]}" >>"$LOG_FILE" 2>&1; then
    log "dispatch accepted: $id (role $ROLE_NAME)"
    return 0
  else
    rc=$?
    log "dispatch failed: $id (executor exit $rc)"
    return 1
  fi
}

launch_command() { # $1=task ID $2=relative path $3=cwd $4=prompt
  local id=$1 rel=$2 cwd=$3 prompt=$4 desc
  local -a args=(--task-id "$id")
  desc="--task-id $id"
  if [ -n "$cwd" ]; then args+=(--cwd "$cwd"); desc+=" --cwd $cwd"; fi
  if [ -n "$ROLE_NAME" ] && [ "$ROLE_NAME" != default ]; then
    args+=(--role "$ROLE_NAME"); desc+=" --role $ROLE_NAME"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would run: $EXECUTOR_BIN_PATH $desc <prompt on stdin>"
    return 0
  fi

  log "dispatch: $EXECUTOR_BIN_PATH $desc <prompt on stdin>"
  local rc _e
  local -a xenv=()
  while IFS= read -r _e; do [ -n "$_e" ] && xenv+=("$_e"); done < <(executor_env)
  if ( export RELAY_TASK_ID="$id" RELAY_TASK_FILE="$rel" RELAY_TASK_CWD="$cwd" \
           RELAY_TASK_ROLE="$ROLE_NAME"; printf '%s\n' "$prompt" ) \
       | env ${xenv[@]+"${xenv[@]}"} "$EXECUTOR_BIN_PATH" "${args[@]}" >>"$LOG_FILE" 2>&1; then
    log "dispatch accepted: $id (executor $EXECUTOR)"
    return 0
  else
    rc=$?
    log "dispatch failed: $id (executor exit $rc)"
    return 1
  fi
}

launch_executor() { # $1=task ID $2=relative path $3=cwd $4=task lock
  local id=$1 rel=$2 cwd=$3 tasklock=$4 prompt
  prompt=$(build_prompt "$id" "$rel" "$tasklock")
  case "$EXECUTOR" in
    paseo) launch_paseo "$id" "$cwd" "$prompt" ;;
    command) launch_command "$id" "$rel" "$cwd" "$prompt" ;;
  esac
}

# ---------------------------------------------------------------- main
main() {
  rotate_log
  log "──── relay-runner start (pid $$, executor $EXECUTOR, checkout $REPO, guard_wait $GUARD_WAIT)"
  trap 'release_git_lock; release_run_lock' EXIT

  if [ -f "$PAUSE_FILE" ]; then
    log "skip: pause marker present ($PAUSE_FILE)"
    return 0
  fi
  acquire_run_lock || return 1
  unblock_executor_push   # recover from an interrupted earlier round
  check_sync_timing || return 0
  repo_ready || return 0

  local tasklock_dir tasks_dir d holders='' oldest age
  tasklock_dir="$GIT_DIR/$TASKLOCK_DIRNAME"
  mkdir -p "$tasklock_dir" 2>/dev/null || { log "skip: cannot create $tasklock_dir"; return 0; }

  tasks_dir="$REPO/$TASKS_SUBDIR"
  [ -d "$tasks_dir" ] || { log "skip: task directory not found: $tasks_dir"; return 0; }

  for d in "$tasklock_dir"/*; do
    [ -d "$d" ] && holders="$holders $(basename "$d")"
  done
  if [ -n "$holders" ]; then
    oldest=$(ls -tr "$tasklock_dir" 2>/dev/null | head -n 1)
    age=0
    [ -n "$oldest" ] && age=$(( $(date +%s) - $(file_mtime "$tasklock_dir/$oldest") ))
    log "no dispatch this round: a task is running or its lock was not released:$holders"
    if [ "$age" -gt "$STALE_TASK_LOCK_SECONDS" ]; then
      log "note: the oldest task lock ($oldest) is ${age}s old; confirm no executor remains, then recover explicitly (locks are never removed by the runner)"
    fi
    return 0
  fi

  local file base id_field updated status file_id rel cwd role_field tasklock found=0
  for file in "$tasks_dir"/*.md; do
    [ -f "$file" ] || continue
    base=$(basename "$file" .md)
    [ "$base" = README ] && continue
    case "$base" in
      ''|*[!a-z0-9-]*|[!a-z0-9]*) log "skip: unsafe task filename: $(basename "$file")"; continue ;;
    esac
    [ ${#base} -le 96 ] || { log "skip: task ID too long: $base"; continue; }

    matches_executor "$(read_field "$file" Executor)" || continue
    status=$(read_field "$file" Status)
    is_pending "$status" || continue

    id_field=$(read_field "$file" 'Task ID')
    updated=$(read_field "$file" Updated)
    if [ -z "$id_field" ] || [ -z "$updated" ]; then
      log "skip: $base lacks a Task ID or Updated header; not a valid protocol task"
      continue
    fi
    if [ "$id_field" != "$base" ]; then
      log "skip: $base has Task ID '$id_field'; the filename and ID must match"
      continue
    fi

    rel="$TASKS_SUBDIR/$base.md"
    if [ -e "$MARKER_DIR/$base" ]; then
      log "skip: $base was already dispatched on this machine ($MARKER_DIR/$base)"
      continue
    fi
    if [ -d "$tasklock_dir/$base" ]; then
      log "skip: task lock already exists for $base; inspect it, do not delete it blindly"
      continue
    fi

    found=1
    log "candidate: $rel"
    if ! mkdir "$tasklock_dir/$base" 2>/dev/null; then
      log "skip: cannot acquire task lock for $base"
      continue
    fi
    tasklock="$tasklock_dir/$base"
    log "task lock acquired: $tasklock"

    status=$(read_field "$file" Status)
    if ! is_pending "$status"; then
      log "release task lock: status changed to ${status:-unknown}; not claiming"
      rmdir "$tasklock" 2>/dev/null || true
      continue
    fi

    # Guard 2 (before claiming): scan the task body; never echo the matched text.
    if ! guard_scan "$file"; then
      log "guard 2 blocked: task body matched sensitive patterns: $GUARD_SCAN_HITS"
      if ! block_task "$file" "$rel" "$base" "Task body matched sensitive patterns: $GUARD_SCAN_HITS"; then
        rmdir "$tasklock" 2>/dev/null || true
        log 'stopping this round: could not record the blocked state'
        return 1
      fi
      rmdir "$tasklock" 2>/dev/null || true
      continue
    fi

    if ! claim_task "$file" "$rel" "$base"; then
      log 'claim failed; releasing the task lock and ending this round without dispatch'
      rmdir "$tasklock" 2>/dev/null || true
      return 1
    fi

    cwd=$(read_field "$file" 'Target directory')
    # No target directory: pin the executor to the task checkout.
    [ -n "$cwd" ] || cwd=$REPO
    role_field=$(read_field "$file" Role)

    if [ -n "$cwd" ]; then
      case "$cwd" in
        /*) ;;
        *) log "target directory is not absolute: $cwd"
           if ! block_task "$file" "$rel" "$base" "Target directory is not an absolute path: $cwd"; then
             rmdir "$tasklock" 2>/dev/null || true
             log 'stopping this round: could not record the blocked state'
             return 1
           fi
           rmdir "$tasklock" 2>/dev/null || true
           continue ;;
      esac
      if [ ! -d "$cwd" ]; then
        log "target directory does not exist: $cwd"
        if ! block_task "$file" "$rel" "$base" "Target directory does not exist: $cwd"; then
          rmdir "$tasklock" 2>/dev/null || true
          log 'stopping this round: could not record the blocked state'
          return 1
        fi
        rmdir "$tasklock" 2>/dev/null || true
        continue
      fi
      if ! dir_allowed "$cwd"; then
        log "guard 1 blocked: $DIR_ERR"
        if ! block_task "$file" "$rel" "$base" "$DIR_ERR"; then
          rmdir "$tasklock" 2>/dev/null || true
          log 'stopping this round: could not record the blocked state'
          return 1
        fi
        rmdir "$tasklock" 2>/dev/null || true
        continue
      fi
      cwd=$(resolve_dir "$cwd")
      log "target directory: $cwd"
    fi

    if ! resolve_executor_bin; then
      log "executor unavailable: $EXECUTOR_ERR"
      if ! block_task "$file" "$rel" "$base" "$EXECUTOR_ERR"; then
        rmdir "$tasklock" 2>/dev/null || true
        log 'stopping this round: could not record the blocked state'
        return 1
      fi
      rmdir "$tasklock" 2>/dev/null || true
      continue
    fi

    if [ "$EXECUTOR" = paseo ]; then
      if [ -n "$role_field" ]; then
        if ! role_lookup "$role_field"; then
          log "role unavailable: $ROLE_ERR"
          if ! block_task "$file" "$rel" "$base" "Role '$role_field' is unavailable: $ROLE_ERR"; then
            rmdir "$tasklock" 2>/dev/null || true
            log 'stopping this round: could not record the blocked state'
            return 1
          fi
          rmdir "$tasklock" 2>/dev/null || true
          continue
        fi
        log "role preset '$ROLE_NAME': provider=$ROLE_PROVIDER model=${ROLE_MODEL:-<none>} mode=${ROLE_MODE:-<unset>} thinking=${ROLE_THINKING:-<unset>}"
      else
        builtin_default_role
        log "task has no Role; using built-in defaults provider=${DEFAULT_PROVIDER:-<executor default>} thinking=${DEFAULT_THINKING:-<executor default>}"
      fi
      if [ -n "$ROLE_PROVIDER" ] && ! provider_available "$ROLE_PROVIDER"; then
        log "provider unavailable: $PROVIDER_ERR"
        if ! block_task "$file" "$rel" "$base" "Provider for role '$ROLE_NAME' is unavailable: $PROVIDER_ERR"; then
          rmdir "$tasklock" 2>/dev/null || true
          log 'stopping this round: could not record the blocked state'
          return 1
        fi
        rmdir "$tasklock" 2>/dev/null || true
        continue
      fi
    else
      ROLE_NAME=${role_field:-default}
      ROLE_NOTES=''
      ROLE_PROVIDER=''; ROLE_MODEL=''; ROLE_MODE=''; ROLE_THINKING=''; ROLE_FEATURE_KEYS=''
      log "command adapter: role=${ROLE_NAME} (no preset lookup)"
    fi

    block_executor_push
    local launch_ok=0
    launch_executor "$base" "$rel" "$cwd" "$tasklock" && launch_ok=1
    unblock_executor_push
    if [ "$launch_ok" = 1 ]; then
      if [ "$DRY_RUN" = 1 ]; then
        rmdir "$tasklock" 2>/dev/null || true
        log '[dry-run] no marker written; task lock released'
        return 0
      fi
      : >"$MARKER_DIR/$base" || log "warning: could not write dispatch marker $MARKER_DIR/$base"
      if [ "$GUARD_WAIT" != 1 ]; then
        log 'round complete: dispatched one task; the task lock stays until that agent releases it (RELAY_GUARD_WAIT=0: output gate not enforced)'
        return 0
      fi

      # Guard 3: the executor has finished; gate its output before pushing.
      local guard_rc=0
      if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
        log 'warning: the executor left uncommitted changes; they are never pushed and the checkout stays dirty until the user inspects it'
      fi
      guard_output || guard_rc=$?
      if [ "$guard_rc" = 0 ]; then
        rmdir "$tasklock" 2>/dev/null || true
        if [ -z "$(git -C "$REPO" rev-list origin/main..HEAD 2>/dev/null)" ]; then
          log "output gate passed: $base (no local commits to push)"
          return 0
        fi
        if push_guarded; then
          log "output gate passed and pushed: $base"
          return 0
        fi
        log "error: output gate passed but push failed; local commits kept for inspection"
        write_pause "task $base passed the output gate but the guarded push failed; inspect git log origin/main..HEAD"
        return 1
      fi
      if [ "$guard_rc" = 1 ]; then
        log "guard 3 blocked: likely secret in output (patterns: $GUARD_OUT_PATTERNS; files: $GUARD_OUT_FILES); nothing pushed"
        block_local "$file" "$rel" "$base" "likely secret in output (patterns: $GUARD_OUT_PATTERNS; files: $GUARD_OUT_FILES)"
        write_pause "task $base output gate hit (patterns: $GUARD_OUT_PATTERNS; files: $GUARD_OUT_FILES)"
      else
        log "guard 3 could not complete ($GUARD_OUT_ERR); nothing pushed"
        block_local "$file" "$rel" "$base" "output gate could not complete: $GUARD_OUT_ERR"
        write_pause "task $base output gate could not complete: $GUARD_OUT_ERR"
      fi
      rmdir "$tasklock" 2>/dev/null || true
      return 1
    fi

    block_task "$file" "$rel" "$base" "Executor failed to start; see the runner log"
    rmdir "$tasklock" 2>/dev/null || true
    return 1
  done

  [ "$found" = 1 ] || log 'nothing to do: no pending task opted in with a matching Executor field'
  return 0
}

main "$@"
exit $?
