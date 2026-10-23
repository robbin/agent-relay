#!/bin/bash
# relay-runner.sh — optional local auto-relay executor (launchd: io.agent-relay.runner)
#
# Usage: bash relay-runner.sh ABSOLUTE_CHECKOUT
#
# launchd calls this every 300 seconds. It scans <checkout>/tasks/to-local/ for
# pending tasks whose `- Executor:` field explicitly matches the configured
# executor adapter, claims at most one task, dispatches it, records execution
# evidence and pushes only the exact commit it verified.
#
# Safety model (see docs/security.md):
#   1. Target directory allowlist: the raw path must not contain `..`; the real
#      path (symlinks resolved) must be inside the checkout, an allowlist entry,
#      or an existing first-level project under RELAY_PROJECTS_ROOT. The
#      checkout's own `.git` directory is refused.
#   2. Task body scan: the task text (everything except pure metadata header
#      lines and the runner's own notes) is matched against sensitive patterns
#      (.ssh, private keys, .env, Keychain, upload commands, ...). A hit blocks
#      the task without starting the executor and without echoing the text.
#   3. Output gate (RELAY_GUARD_WAIT=1, the only supported mode): the executor
#      commits but does not push; the runner waits for it, records execution
#      evidence, scans every commit it would push (commit metadata, every
#      changed blob, large/binary files fail closed) and pushes only that exact
#      commit. A hit writes PAUSED and pushes nothing. RELAY_GUARD_WAIT=0 is
#      refused: without the final exit status no push authorization can be
#      issued safely.
#
# Execution evidence: before the executor starts, the runner creates
# <git-dir>/agent-relay-execution/ with an owner token, the task ID and the base
# commit. Only the round that owns the directory may bind an approved HEAD to
# it; unknown or failed results stay quarantined (hold/) and are never pushed
# automatically. A push that cannot be verified against that evidence is
# refused, so deleting PAUSED alone never authorizes a push.
#
# Push validation: a guarded push may only carry the terminal transition of the
# task this round owns (pending->accepted by this runner, accepted->done by the
# approved execution, accepted->blocked by this runner or by that execution).
# Any other to-local/to-cloud change, a receipt that disagrees with the task, a
# reverse receipt, a rename or a deletion is refused and keeps the local scene.
#
# Blocked tasks get a receipt (tasks/receipts/to-cloud/<ID>.md) when the task
# carries `- Receipt: required`; the reason distinguishes "blocked before
# dispatch" from "the executor ran and may have had side effects".
#
# The runner NEVER fetches, pulls, merges, rebases, stashes, resets or force
# pushes. It relies on the separate pull-only sync timer and refuses to act on a
# checkout that is not clean and at exactly origin/main.
#
# The runner never executes task text as shell source. It passes the task scope
# and safety rules to an executor agent as a prompt.
#
# Configuration is by environment variable; every path below has a default but
# nothing machine-specific is embedded. See docs/setup-local-macos.md.
#
# Exit codes: 0 = normal (including nothing to do); 1 = error/skip (logged).

set -uo pipefail

# Never let a local replace ref rewrite the history that is about to be scanned.
export GIT_NO_REPLACE_OBJECTS=1

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

usage() { echo 'usage: bash relay-runner.sh ABSOLUTE_CHECKOUT' >&2; }

# Sourcing the file for offline tests (RELAY_RUNNER_SOURCE_ONLY=1) ignores a
# positional argument and uses RELAY_REPO instead.
if [ "${RELAY_RUNNER_SOURCE_ONLY:-0}" = 1 ]; then
  CHECKOUT_ARG=${RELAY_REPO:-}
else
  CHECKOUT_ARG=${1:-${RELAY_REPO:-}}
fi
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
PAUSE_FILE="$STATE_DIR/PAUSED"
GITLOCK_NAME=agent-relay-git.lock
TASKLOCK_DIRNAME=agent-relay-task-locks
EXECUTION_DIRNAME=agent-relay-execution
RECEIPT_SUBDIR=tasks/receipts/to-cloud

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
# 1 = wait for the executor, gate its output, then push. 0 is refused.
GUARD_WAIT=${RELAY_GUARD_WAIT:-1}
# Pending commits are refused when a changed blob exceeds this size or is binary,
# unless its path matches one of the colon-separated RELAY_GUARD_BLOB_ALLOW globs.
GUARD_BLOB_MAX=${RELAY_GUARD_BLOB_MAX:-1048576}
GUARD_BLOB_ALLOW=${RELAY_GUARD_BLOB_ALLOW:-}

# Optional identity check for origin; empty disables the check.
EXPECTED_ORIGIN=${RELAY_EXPECTED_ORIGIN:-}

MIN_SECONDS_AFTER_SYNC=${RELAY_MIN_SECONDS_AFTER_SYNC:-30}
MAX_SYNC_AGE=${RELAY_MAX_SYNC_AGE:-1500}
PUSH_RETRIES=${RELAY_PUSH_RETRIES:-3}
PUSH_RETRY_DELAY=${RELAY_PUSH_RETRY_DELAY:-10}
GITLOCK_TRIES=${RELAY_GITLOCK_TRIES:-20}
GITLOCK_SLEEP=${RELAY_GITLOCK_SLEEP:-3}
STALE_TASK_LOCK_SECONDS=${RELAY_STALE_TASK_LOCK_SECONDS:-1800}
MAX_LOG_BYTES=${RELAY_MAX_LOG_BYTES:-10485760}
DRY_RUN=${RELAY_RUNNER_DRY_RUN:-0}

for _v in MIN_SECONDS_AFTER_SYNC MAX_SYNC_AGE PUSH_RETRIES PUSH_RETRY_DELAY \
          GITLOCK_TRIES GITLOCK_SLEEP STALE_TASK_LOCK_SECONDS MAX_LOG_BYTES GUARD_BLOB_MAX; do
  case "${!_v}" in
    ''|*[!0-9]*) echo "invalid numeric setting $_v=${!_v}" >&2; exit 1 ;;
  esac
done
if [ "$GUARD_WAIT" != 1 ]; then
  echo "unsupported RELAY_GUARD_WAIT=$GUARD_WAIT (only 1 is supported: without the final exit status no push authorization can be issued)" >&2
  exit 1
fi
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

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$MARKER_DIR" 2>/dev/null || true

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

# Task IDs are used to build paths (task lock, dispatch marker, receipt), so
# only the protocol form is accepted: [a-z0-9][a-z0-9-]{0,95}.
valid_task_id() {
  case "$1" in
    ''|*..*|*/*|*[!a-z0-9-]*|[!a-z0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 96 ] || return 1
  return 0
}

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
    base=$(resolve_dir "$entry") || { log "note: allowlist entry is unavailable and was ignored: $entry"; continue; }
    if [ "$candidate" = "$base" ]; then return 0; fi
    case "$candidate" in "$base"/*) return 0 ;; esac
  done
  unset IFS
  if [ -n "$PROJECTS_ROOT" ] && base=$(resolve_dir "$PROJECTS_ROOT"); then
    case "$candidate" in
      "$base"/?*)
        rel=${candidate#"$base"/}
        first=${rel%%/*}
        [ -n "$first" ] && [ -d "$base/$first" ] && [ "$(resolve_dir "$base/$first")" = "$base/$first" ] && return 0
        ;;
    esac
  elif [ -n "$PROJECTS_ROOT" ]; then
    log "note: RELAY_PROJECTS_ROOT is unavailable and was ignored: $PROJECTS_ROOT"
  fi
  DIR_ERR="Target directory is outside the configured allowlist: $raw"
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
# skipped (Task ID, Status, Executor, Role, Target directory, Receipt).
# Everything else, including "- Task:", "- Constraints:", "- Inputs:" and any
# pre-filled Result text, is scanned: a pending task's Result should be empty.
# Sets GUARD_SCAN_HITS (pattern names only).
# Returns 0 = clean, 1 = sensitive content, 2 = the check itself failed.
guard_scan() { # $1=task file
  local file=$1 body pat hits='' rc=0
  GUARD_SCAN_HITS=''
  body=$(mktemp "$STATE_DIR/scan.XXXXXX") || { GUARD_SCAN_HITS='cannot create a temp file'; return 2; }
  if ! awk '
    { low = tolower($0) }
    low ~ /^-[ \t]*(task id|status|executor|role|target directory|receipt)[ \t]*:/ { next }
    # Notes appended by the runner itself (so a fixed task can be recovered).
    /^- Runner: (dispatch|output gate) blocked (this task )?at [0-9TZ:-]+: / { next }
    /^- Needed: (fix the cause above|nothing was pushed)\. / { next }
    { print }
  ' "$file" >"$body" 2>/dev/null; then
    rm -f "$body"; GUARD_SCAN_HITS='cannot read the task body'; return 2
  fi
  for pat in "${GUARD_SENSITIVE_PATTERNS[@]}"; do
    [ -n "$pat" ] || continue
    rc=0
    LC_ALL=C grep -Eqi -- "$pat" "$body" 2>/dev/null || rc=$?
    case "$rc" in
      0) hits="${hits}${pat}"$'\n' ;;
      1) ;;
      *) rm -f "$body"; GUARD_SCAN_HITS='the task body scan failed'; return 2 ;;
    esac
  done
  for pat in "${GUARD_SENSITIVE_PATTERNS_UTF8[@]}"; do
    [ -n "$pat" ] || continue
    rc=0
    grep -Fq -- "$pat" "$body" 2>/dev/null || rc=$?
    case "$rc" in
      0) hits="${hits}${pat}"$'\n' ;;
      1) ;;
      *) rm -f "$body"; GUARD_SCAN_HITS='the task body scan failed'; return 2 ;;
    esac
  done
  rm -f "$body"
  if [ -n "$hits" ]; then
    GUARD_SCAN_HITS=$(normalize_hits "$hits") || { GUARD_SCAN_HITS='cannot summarize the hits'; return 2; }
    return 1
  fi
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

normalize_hits() { printf '%s\n' "$1" | awk 'NF && !seen[$0]++' | tr '\n' ';' | sed -e 's/;$//'; }

blob_allowed() {
  local p=$1 g
  local -a globs
  [ -n "$GUARD_BLOB_ALLOW" ] || return 1
  IFS=':' read -r -a globs <<<"$GUARD_BLOB_ALLOW"
  for g in "${globs[@]}"; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254  # the globs are meant to expand here
    case "$p" in $g) return 0 ;; esac
  done
  return 1
}

# Scan every commit in <base>..<head> against every parent (so merge-only
# content is covered): the full commit object (title, body, author, signature
# headers) and each changed blob. Large or binary blobs fail closed unless the
# path matches RELAY_GUARD_BLOB_ALLOW. -z keeps arbitrary file names intact.
# Returns 0 = clean, 1 = refused content, 2 = the check itself failed.
# Sets GUARD_OUT_PATTERNS, GUARD_OUT_FILES, GUARD_OUT_ERR (names only).
scan_pending_commits() { # $1=end OID (default HEAD) $2=base OID (default origin/main)
  local head=${1:-HEAD} base=${2:-origin/main} dir c meta path mode sha status size pat rc
  local patterns='' files=''
  GUARD_OUT_PATTERNS=''; GUARD_OUT_FILES=''; GUARD_OUT_ERR=''
  cd "$REPO" || { GUARD_OUT_ERR='the checkout is unavailable'; return 2; }
  dir=$(mktemp -d "$STATE_DIR/guard.XXXXXX") || { GUARD_OUT_ERR='mktemp -d failed'; return 2; }
  if ! git rev-list "$base..$head" >"$dir/commits"; then
    GUARD_OUT_ERR='cannot list the commits to push'; rm -rf "$dir"; return 2
  fi
  while IFS= read -r c; do
    git cat-file commit "$c" >"$dir/commit" || {
      GUARD_OUT_ERR='cannot read a commit object'; rm -rf "$dir"; return 2;
    }
    for pat in "${GUARD_SECRET_PATTERNS[@]}"; do
      rc=0
      LC_ALL=C grep -a -E -- "$pat" "$dir/commit" >/dev/null 2>&1 || rc=$?
      case "$rc" in
        0) patterns="${patterns}${pat}"$'\n'; files="${files}commit@${c:0:12}"$'\n' ;;
        1) ;;
        *) GUARD_OUT_ERR='cannot scan a commit object'; rm -rf "$dir"; return 2 ;;
      esac
    done
    if ! git diff-tree -m -r --root --no-commit-id --no-renames --no-ext-diff -z "$c" >"$dir/tree"; then
      GUARD_OUT_ERR='cannot list the changed paths'; rm -rf "$dir"; return 2
    fi
    while IFS= read -r -d '' meta; do
      IFS= read -r -d '' path || { GUARD_OUT_ERR='truncated diff-tree record'; rm -rf "$dir"; return 2; }
      # Raw metadata never contains a user path; no glob expansion here.
      # shellcheck disable=SC2034  # positional fields of the raw record
      IFS=' ' read -r _oldmode mode _oldsha sha status <<<"$meta"
      case "$status" in D) continue ;; A|M|T) ;; *) GUARD_OUT_ERR='unknown diff status'; rm -rf "$dir"; return 2 ;; esac
      case "$mode" in
        100644|100755|120000) ;;
        *) GUARD_OUT_ERR='unsupported object mode (submodule?)'; rm -rf "$dir"; return 2 ;;
      esac
      size=$(git cat-file -s "$sha") || { GUARD_OUT_ERR='cannot read a blob size'; rm -rf "$dir"; return 2; }
      case "$size" in ''|*[!0-9]*) GUARD_OUT_ERR='invalid blob size'; rm -rf "$dir"; return 2 ;; esac
      if [ "$size" -gt "$GUARD_BLOB_MAX" ]; then
        if blob_allowed "$path"; then
          log "note: explicitly allowed large file, content not scanned: $path"
          continue
        fi
        patterns="${patterns}blob over the size limit"$'\n'; files="${files}${path}@${c:0:12}"$'\n'
        continue
      fi
      git cat-file blob "$sha" >"$dir/blob" || { GUARD_OUT_ERR='cannot read a blob'; rm -rf "$dir"; return 2; }
      if [ "$size" -gt 0 ]; then
        rc=0
        LC_ALL=C grep -I '' "$dir/blob" >/dev/null 2>&1 || rc=$?
        case "$rc" in
          0) ;;
          1)
            if blob_allowed "$path"; then log "note: explicitly allowed binary file, content not scanned: $path"; continue; fi
            patterns="${patterns}binary file"$'\n'; files="${files}${path}@${c:0:12}"$'\n'
            continue ;;
          *) GUARD_OUT_ERR='cannot classify a blob as text'; rm -rf "$dir"; return 2 ;;
        esac
      fi
      for pat in "${GUARD_SECRET_PATTERNS[@]}"; do
        [ -n "$pat" ] || continue
        rc=0
        LC_ALL=C grep -E -- "$pat" "$dir/blob" >/dev/null 2>&1 || rc=$?
        case "$rc" in
          0) patterns="${patterns}${pat}"$'\n'; files="${files}${path}@${c:0:12}"$'\n' ;;
          1) ;;
          *) GUARD_OUT_ERR='cannot scan a blob'; rm -rf "$dir"; return 2 ;;
        esac
      done
    done <"$dir/tree"
  done <"$dir/commits"
  rm -rf "$dir"
  if [ -n "$patterns" ]; then
    GUARD_OUT_PATTERNS=$(normalize_hits "$patterns")
    GUARD_OUT_FILES=$(normalize_hits "$files")
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- run lock
# The run lock is private to this script and is never reclaimed automatically: a
# missing, empty or dead-pid lock does not prove that no executor is still
# running. Recovery is an explicit operator step (see docs/setup-local-macos.md).
RUN_LOCK_OWNED=0
acquire_run_lock() {
  mkdir -p "$STATE_DIR" "$MARKER_DIR" || { log 'error: cannot create the state directory'; return 1; }
  if ! mkdir "$RUN_LOCK" 2>/dev/null; then
    log "skip: the run lock exists or cannot be created ($RUN_LOCK); inspect it before resuming"
    return 1
  fi
  RUN_LOCK_OWNED=1
  if ! printf '%s\n' "$$" >"$RUN_LOCK/pid"; then
    log 'error: cannot write the run lock pid; leaving the incomplete lock for manual verification'
    RUN_LOCK_OWNED=0
    return 1
  fi
  return 0
}

release_run_lock() {
  [ "$RUN_LOCK_OWNED" = 1 ] || return 0
  [ -f "$RUN_LOCK/pid" ] && [ ! -L "$RUN_LOCK/pid" ] || return 1
  [ "$(cat "$RUN_LOCK/pid" 2>/dev/null)" = "$$" ] || return 1
  rm "$RUN_LOCK/pid" && rmdir "$RUN_LOCK" || return 1
  RUN_LOCK_OWNED=0
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

# ---------------------------------------------------------------- execution evidence
# Execution evidence is not a pause marker: it is written before dispatch so an
# unknown or failed result never has an approved HEAD. It records only local
# proof (no secrets), is never committed and survives deleting PAUSED.
EXECUTION_TOKEN=''
EXECUTION_DIR=''
# Only the runner's own claim/dispatch may transition a task; never inherit an
# authorization context from the environment.
CONTROL_TASK_ID=''
CONTROL_ACTION=''

execution_path() {
  local gd
  gd=$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  EXECUTION_DIR="$gd/$EXECUTION_DIRNAME"
}

execution_exists() { [ -n "$EXECUTION_DIR" ] && { [ -e "$EXECUTION_DIR" ] || [ -L "$EXECUTION_DIR" ]; }; }

begin_execution() {
  EXECUTION_TOKEN="$$-$RANDOM-$RANDOM"
  with_git_lock begin_execution_locked "$1"
}

begin_execution_locked() {
  local id=$1 rel="$TASKS_SUBDIR/$1.md" dirty
  validate_locked_repo && execution_path || return 1
  pause_present && return 1
  validate_task_identity "$REPO/$rel" "$rel" "$id" || return 1
  [ "$(read_field "$REPO/$rel" Status)" = accepted ] || return 1
  dirty=$(git status --porcelain -uall 2>/dev/null) || return 1
  [ -z "$dirty" ] && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || return 1
  # Never overwrite an unknown earlier result; an empty or broken record is refused too.
  mkdir "$EXECUTION_DIR" || { log 'push blocked: execution evidence already exists or cannot be created; not dispatching'; return 1; }
  { printf '%s\n' "$EXECUTION_TOKEN" >"$EXECUTION_DIR/owner" &&
    printf '%s\n' "$id" >"$EXECUTION_DIR/task-id" &&
    git rev-parse HEAD >"$EXECUTION_DIR/base"; } || {
      log 'error: cannot initialize the execution evidence; keeping the directory and not dispatching'
      return 1
    }
}

quarantine_execution() { # called by the Git lock holder; keeps the task, records manual verification
  local id=$1
  execution_path || return 1
  if ! execution_exists; then
    mkdir "$EXECUTION_DIR" || { log 'error: cannot persist the execution quarantine'; return 1; }
    printf '%s\n' "$id" >"$EXECUTION_DIR/task-id" || return 1
  fi
  [ -d "$EXECUTION_DIR" ] && [ ! -L "$EXECUTION_DIR" ] || return 1
  if [ ! -e "$EXECUTION_DIR/hold" ] && [ ! -L "$EXECUTION_DIR/hold" ]; then
    mkdir "$EXECUTION_DIR/hold" || return 1
  fi
  write_pause "task $id needs manual verification of its execution result; the original task and receipt are kept and nothing is pushed automatically" || {
    log 'note: no new PAUSED file was created (a blocker may exist already, or an I/O error); the execution evidence still refuses pushes'
    return 1
  }
}

authorize_execution_locked() { # only this round may bind a verified terminal state to an exact HEAD
  local id=$1 tmp
  execution_path || return 1
  execution_exists || return 0 # blocked before dispatch: no execution happened
  [ -d "$EXECUTION_DIR" ] && [ ! -L "$EXECUTION_DIR" ] || return 1
  [ ! -e "$EXECUTION_DIR/hold" ] && [ ! -L "$EXECUTION_DIR/hold" ] || return 1
  [ -n "$EXECUTION_TOKEN" ] &&
    [ "$(cat "$EXECUTION_DIR/owner" 2>/dev/null)" = "$EXECUTION_TOKEN" ] &&
    [ "$(cat "$EXECUTION_DIR/task-id" 2>/dev/null)" = "$id" ] || return 1
  tmp=$(mktemp "$EXECUTION_DIR/approve.XXXXXX") || return 1
  git rev-parse HEAD >"$tmp" && mv "$tmp" "$EXECUTION_DIR/approved-head"
}

check_execution_locked() { # $1=the exact HEAD to push; a retry must re-check the record
  local head=$1 approved base f
  PUSH_EXECUTION_ID=''
  execution_path || return 1
  execution_exists || return 0
  [ -d "$EXECUTION_DIR" ] && [ ! -L "$EXECUTION_DIR" ] || return 1
  [ ! -e "$EXECUTION_DIR/hold" ] && [ ! -L "$EXECUTION_DIR/hold" ] || return 1
  for f in owner task-id base approved-head; do
    [ -f "$EXECUTION_DIR/$f" ] && [ ! -L "$EXECUTION_DIR/$f" ] || return 1
  done
  approved=$(cat "$EXECUTION_DIR/approved-head") &&
    base=$(cat "$EXECUTION_DIR/base") &&
    PUSH_EXECUTION_ID=$(cat "$EXECUTION_DIR/task-id") || return 1
  valid_task_id "$PUSH_EXECUTION_ID" && [ "$approved" = "$head" ] || return 1
  git merge-base --is-ancestor "$base" "$head" || return 1
}

clear_approved_execution_locked() {
  check_execution_locked "$1" || return 1
  execution_exists || return 0
  # Never recurse into unknown content; an interrupted cleanup refuses pushes later.
  rm "$EXECUTION_DIR/approved-head" "$EXECUTION_DIR/owner" "$EXECUTION_DIR/task-id" "$EXECUTION_DIR/base" &&
    rmdir "$EXECUTION_DIR"
}

complete_execution() {
  with_git_lock complete_execution_locked "$@"
}

complete_execution_locked() {
  local file=$1 rel=$2 id=$3 status receipt
  validate_locked_repo && validate_task_identity "$file" "$rel" "$id" || return 1
  status=$(read_field "$file" Status)
  case "$status" in done|blocked) ;; *) quarantine_execution "$id"; return 1 ;; esac
  if [ "$(read_field "$file" Receipt)" = required ]; then
    receipt="$REPO/$RECEIPT_SUBDIR/$id.md"
    if [ ! -f "$receipt" ] || [ -L "$receipt" ] ||
        [ "$(read_field "$receipt" 'Task ID')" != "$id" ] ||
        [ "$(read_field "$receipt" 'Original task')" != "$rel" ] ||
        [ "$(read_field "$receipt" 'Result status')" != "$status" ]; then
      quarantine_execution "$id"
      return 1
    fi
  fi
  authorize_execution_locked "$id" && push_guarded_locked
}

# Check the receipt referenced by a task even when the receipt itself is not in
# the diff, so raising a status alone cannot create a one-sided result.
validate_task_receipt_pair() { # $1=head $2=base $3=id $4=task blob $5=scratch dir
  local head=$1 base=$2 id=$3 task=$4 dir=$5 path status
  path="$RECEIPT_SUBDIR/$id.md"
  status=$(read_field "$task" Status)
  git ls-tree "$base" -- "$path" >"$dir/receipt-base-tree" &&
    git ls-tree "$head" -- "$path" >"$dir/receipt-head-tree" || return 1
  if [ -s "$dir/receipt-base-tree" ]; then
    git cat-file blob "$base:$path" >"$dir/receipt-base" &&
      git cat-file blob "$head:$path" >"$dir/receipt-head" &&
      cmp -s "$dir/receipt-base" "$dir/receipt-head" || return 1
  fi
  if [ ! -s "$dir/receipt-head-tree" ]; then
    case "$status:$(read_field "$task" Receipt)" in done:required|blocked:required) return 1 ;; esac
    return 0
  fi
  git cat-file blob "$head:$path" >"$dir/receipt-head" || return 1
  [ "$(read_field "$dir/receipt-head" 'Task ID')" = "$id" ] &&
    [ "$(read_field "$dir/receipt-head" 'Original task')" = "$TASKS_SUBDIR/$id.md" ] &&
    [ "$(read_field "$dir/receipt-head" 'Result status')" = "$status" ]
}

# Pending control files may only carry the transition this round owns. No other
# task may ride along, no historical task may be added/deleted/renamed, and
# reverse receipts, to-cloud files and the protocol file stay read-only.
validate_pending_protocol() { # $1=head $2=base; the execution approval was re-checked already
  local head=$1 base=$2 dir path id old status allowed
  allowed=${PUSH_EXECUTION_ID:-$CONTROL_TASK_ID}
  dir=$(mktemp -d "$STATE_DIR/protocol.XXXXXX") || return 1
  if ! git diff --no-renames --name-only -z "$base" "$head" -- \
      "$TASKS_SUBDIR/" tasks/to-cloud/ tasks/receipts/ tasks/README.md >"$dir/list"; then
    rm -rf "$dir"; return 1
  fi
  while IFS= read -r -d '' path; do
    case "$path" in
      "$TASKS_SUBDIR"/*.md)
        id=${path#"$TASKS_SUBDIR"/}; id=${id%.md}
        valid_task_id "$id" && [ "$id" = "$allowed" ] || { rm -rf "$dir"; return 1; }
        # Both sides must exist as blobs: deletion, rename and local additions are refused.
        git cat-file blob "$base:$path" >"$dir/base-task" &&
          git cat-file blob "$head:$path" >"$dir/head-task" || { rm -rf "$dir"; return 1; }
        [ "$(read_field "$dir/base-task" 'Task ID')" = "$id" ] &&
          [ "$(read_field "$dir/head-task" 'Task ID')" = "$id" ] &&
          [ "$(read_field "$dir/base-task" Receipt)" = "$(read_field "$dir/head-task" Receipt)" ] || {
            rm -rf "$dir"; return 1;
          }
        old=$(read_field "$dir/base-task" Status); status=$(read_field "$dir/head-task" Status)
        case "$old:$status" in
          pending:accepted)
            [ -z "$PUSH_EXECUTION_ID" ] && [ "$CONTROL_TASK_ID" = "$id" ] &&
              [ "$CONTROL_ACTION" = claim ] || { rm -rf "$dir"; return 1; } ;;
          accepted:done)
            [ "$PUSH_EXECUTION_ID" = "$id" ] || { rm -rf "$dir"; return 1; } ;;
          accepted:blocked)
            if [ "$PUSH_EXECUTION_ID" != "$id" ]; then
              [ "$CONTROL_TASK_ID" = "$id" ] && [ "$CONTROL_ACTION" = blocked ] || {
                rm -rf "$dir"; return 1;
              }
            fi ;;
          *) rm -rf "$dir"; return 1 ;;
        esac
        validate_task_receipt_pair "$head" "$base" "$id" "$dir/head-task" "$dir" || {
          rm -rf "$dir"; return 1;
        } ;;
      "$RECEIPT_SUBDIR"/*.md)
        id=${path#"$RECEIPT_SUBDIR"/}; id=${id%.md}
        valid_task_id "$id" && [ "$id" = "$allowed" ] || { rm -rf "$dir"; return 1; }
        git ls-tree "$base" -- "$path" >"$dir/old-receipt" &&
          git cat-file blob "$base:$TASKS_SUBDIR/$id.md" >"$dir/base-task" &&
          git cat-file blob "$head:$TASKS_SUBDIR/$id.md" >"$dir/head-task" || {
            rm -rf "$dir"; return 1;
          }
        [ ! -s "$dir/old-receipt" ] &&
          [ "$(read_field "$dir/base-task" 'Task ID')" = "$id" ] &&
          [ "$(read_field "$dir/head-task" 'Task ID')" = "$id" ] &&
          [ "$(read_field "$dir/base-task" Status)" = accepted ] || { rm -rf "$dir"; return 1; }
        status=$(read_field "$dir/head-task" Status)
        case "$status" in
          done) [ "$PUSH_EXECUTION_ID" = "$id" ] || { rm -rf "$dir"; return 1; } ;;
          blocked)
            if [ "$PUSH_EXECUTION_ID" != "$id" ]; then
              [ "$CONTROL_ACTION" = blocked ] && [ "$CONTROL_TASK_ID" = "$id" ] || {
                rm -rf "$dir"; return 1;
              }
            fi ;;
          *) rm -rf "$dir"; return 1 ;;
        esac
        validate_task_receipt_pair "$head" "$base" "$id" "$dir/head-task" "$dir" || {
          rm -rf "$dir"; return 1;
        } ;;
      *) log "push blocked: the local runner must not change this control path: $path"; rm -rf "$dir"; return 1 ;;
    esac
  done <"$dir/list"
  rm -rf "$dir"
}

# ---------------------------------------------------------------- repository state
repo_ready() {
  local branch marker head origin ahead behind
  [ "$(git -C "$REPO" rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
    || { log "error: $REPO is not a Git worktree"; return 1; }
  [ "$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)" = "$REPO" ] \
    || { log "error: $REPO must be the repository root"; return 1; }

  if [ -n "$EXPECTED_ORIGIN" ]; then
    [ "$(git -C "$REPO" remote get-url origin 2>/dev/null || true)" = "$EXPECTED_ORIGIN" ] \
      || { log 'error: origin does not match RELAY_EXPECTED_ORIGIN'; return 1; }
  fi

  branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$branch" = main ] || { log "skip: branch is ${branch:-unknown}, not main"; return 1; }

  GIT_DIR=$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null) \
    || { log 'error: cannot resolve the Git directory'; return 1; }
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

  execution_path || { log 'error: cannot resolve the execution evidence path'; return 1; }
  if [ "$head" = "$origin" ] && execution_exists; then
    log 'skip: execution evidence is still present; the next task cannot be claimed'
    write_pause 'HEAD equals origin/main but execution evidence remains; verify the delivery and its side effects, then recover manually'
    return 1
  fi

  if [ "$head" != "$origin" ]; then
    ahead=$(git -C "$REPO" rev-list --count origin/main..HEAD 2>/dev/null)
    behind=$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null)
    case "$ahead" in ''|*[!0-9]*) log "skip: cannot compare HEAD ($head) with origin/main"; return 1 ;; esac
    case "$behind" in ''|*[!0-9]*) log "skip: cannot compare HEAD ($head) with origin/main"; return 1 ;; esac
    if [ "$behind" != 0 ]; then
      log "skip: the checkout is behind or diverged (ahead ${ahead}, behind ${behind}); wait for sync to fast-forward"
      return 1
    fi
    if [ "$ahead" = 0 ]; then
      log "skip: HEAD differs from origin/main without local commits ($head vs ${origin})"
      return 1
    fi
    log "found ${ahead} unpushed local commits (HEAD ${head:0:12}); attempting a guarded flush"
    if ! flush_pending_commits "$ahead"; then
      log 'skip: the guarded flush did not complete; no new task is dispatched this round'
      return 1
    fi
    head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)
    origin=$(git -C "$REPO" rev-parse origin/main 2>/dev/null || true)
    if [ "$head" != "$origin" ]; then
      log "skip: HEAD still differs from origin/main after the flush ($head vs ${origin}); left for manual review"
      return 1
    fi
  fi
  log "checkout ok: main, clean, at origin/main (${head:0:12})"
  return 0
}

# Flush unpushed local commits created outside the claim/exit path (manual
# recovery, hand-edited task files) through the same guarded push.
flush_pending_commits() { # $1=ahead count
  local ahead=$1
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would flush ${ahead} local commit(s); each is scanned before pushing"
    return 0
  fi
  if push_guarded; then
    log "guarded flush complete: ${ahead} local commit(s) reached the remote"
    return 0
  fi
  log 'error: the guarded flush did not complete; the local commits are kept (a PAUSED marker may need manual handling)'
  return 1
}

# ---------------------------------------------------------------- Git writes
# Every Git write happens under the shared mkdir lock used by sync.sh. The lock
# is released on `exit`, so early returns cannot leak it.
GITLOCK_HELD=''
git_lock_acquire() {
  local gd i
  [ -z "$GITLOCK_HELD" ] || { log 'error: nested Git lock acquisition is forbidden'; return 1; }
  cd "$REPO" || return 1
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  i=1
  while [ "$i" -le "$GITLOCK_TRIES" ]; do
    if mkdir "$gd/$GITLOCK_NAME" 2>/dev/null; then
      GITLOCK_HELD="$gd/$GITLOCK_NAME"
      printf 'relay-runner pid=%s time=%s\n' "$$" "$(now_utc)" >"$GITLOCK_HELD/owner" || {
        rmdir "$GITLOCK_HELD" 2>/dev/null
        GITLOCK_HELD=''
        return 1
      }
      return 0
    fi
    log "shared Git lock is held ($gd/$GITLOCK_NAME); waiting ($i/$GITLOCK_TRIES)"
    [ "$i" -lt "$GITLOCK_TRIES" ] && sleep "$GITLOCK_SLEEP"
    i=$((i + 1))
  done
  log 'error: the shared Git lock is unavailable; nothing is written, committed or pushed'
  return 1
}

git_lock_release() {
  [ -n "$GITLOCK_HELD" ] || return 0
  rm -f "$GITLOCK_HELD/owner"
  rmdir "$GITLOCK_HELD" 2>/dev/null || log "note: the Git lock could not be released: $GITLOCK_HELD"
  GITLOCK_HELD=''
}

with_git_lock() { # the subshell traps cover every early return
  (
    git_lock_acquire || exit 1
    trap 'git_lock_release' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@"
  )
}

validate_locked_repo() {
  local gd f
  [ -n "$GITLOCK_HELD" ] && [ -d "$GITLOCK_HELD" ] || return 1
  cd "$REPO" || return 1
  [ "$(git symbolic-ref -q HEAD)" = refs/heads/main ] || { log 'abort: the branch is no longer main (checked under the lock)'; return 1; }
  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [ ! -e "$gd/$f" ] || { log "abort: unfinished Git operation $f"; return 1; }
  done
  git merge-base --is-ancestor origin/main HEAD || { log 'abort: behind or diverged; waiting for a safe sync'; return 1; }
  git diff --cached --quiet || { log 'abort: the index is not empty or cannot be checked; keeping the scene'; return 1; }
}

validate_task_identity() { # $1=file $2=repo-relative path $3=task ID
  local file=$1 rel=$2 id=$3
  valid_task_id "$id" &&
    [ "$rel" = "$TASKS_SUBDIR/$id.md" ] &&
    [ "$file" = "$REPO/$rel" ] &&
    [ -f "$file" ] && [ ! -L "$file" ] &&
    [ "$(read_field "$file" 'Task ID')" = "$id" ] || {
      log 'abort: the task ID is unsafe, does not match the filename, or the task file is unusable'
      return 1
    }
}

commit_paths_locked() { # $1=message $2...=repo-relative paths
  local msg=$1 rc=0; shift
  validate_locked_repo || return 1
  [ "$#" -gt 0 ] || return 1
  git add -- "$@" || return 1
  git diff --cached --quiet -- "$@" || rc=$?
  [ "$rc" = 0 ] && return 3
  [ "$rc" = 1 ] || return 1
  git commit -q -m "$msg" -- "$@" || { log 'error: the exact-path commit failed'; return 1; }
}

commit_and_push_locked() {
  local rc=0
  commit_paths_locked "$@" || rc=$?
  case "$rc" in 0|3) push_guarded_locked ;; *) return 1 ;; esac
}

commit_push() { with_git_lock commit_and_push_locked "$@"; }

# ---------------------------------------------------------------- claim
# Only this task file is written, committed and pushed, and only while holding
# the shared Git lock; everything is re-validated inside the lock.
claim_task() {
  with_git_lock claim_task_locked "$@"
}

claim_task_locked() {
  local file=$1 rel=$2 id=$3 ts tmp status
  local CONTROL_TASK_ID="$id" CONTROL_ACTION=claim
  validate_locked_repo || return 1
  validate_task_identity "$file" "$rel" "$id" || return 1
  [ "$(read_field "$file" Status)" = pending ] || return 1
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || return 1
  status=$(git status --porcelain -uall 2>/dev/null) || return 1
  [ -z "$status" ] || { log 'claim aborted: the working tree is dirty'; return 1; }
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would claim $rel as accepted (no file or Git change made)"
    return 0
  fi
  ts=$(now_utc)
  tmp=$(mktemp "$STATE_DIR/tmp.XXXXXX") || return 1
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
  ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  grep -q '^- Status: accepted$' "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  commit_and_push_locked "Claim task $id: status accepted" "$rel" || return 1
  log "claimed and pushed: $rel (accepted, $ts)"
}

# ---------------------------------------------------------------- blocked tasks
block_task() { with_git_lock block_task_locked "$@"; }

block_task_locked() { # $1=file $2=rel $3=id $4=reason [$5=before|after]
  local file=$1 rel=$2 id=$3 reason=$4 phase=${5:-before} ts tmp rc=0
  local CONTROL_TASK_ID="$id" CONTROL_ACTION=blocked
  local -a paths
  validate_locked_repo || return 1
  validate_task_identity "$file" "$rel" "$id" || return 1
  case "$(read_field "$file" Status)" in
    done)
      # Keep a completion claim but never treat it as a successful execution.
      quarantine_execution "$id"
      return 1 ;;
    accepted|blocked) ;;
    *) quarantine_execution "$id"; return 1 ;;
  esac
  # The executor may already have committed a done receipt; never rewrite an
  # immutable receipt, and never push a state that disagrees with it.
  validate_existing_blocked_receipt "$rel" "$id" || return 1
  [ "$phase" = after ] && reason="the executor was started and then failed, so partial side effects are possible; check the progress before recovering. $reason"
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would mark $rel blocked: $reason"
    return 0
  fi
  ts=$(now_utc)
  tmp=$(mktemp "$STATE_DIR/tmp.XXXXXX") || return 1
  awk -v ts="$ts" -v reason="$reason" '
    BEGIN { status_done = 0; updated_done = 0; result_done = 0 }
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
  ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  paths=("$rel")
  write_blocked_receipt "$file" "$rel" "$id" "$reason" "$ts" "$phase" || rc=$?
  case "$rc" in
    0) paths+=("$RECEIPT_REL") ;;
    1) ;; # no receipt needed, or a consistent one already exists
    *) log 'error: the receipt could not be written; keeping the local scene without committing or pushing'; return 1 ;;
  esac
  local crc=0
  commit_paths_locked "Task $id: blocked" "${paths[@]}" || crc=$?
  case "$crc" in 0|3) ;; *) return 1 ;; esac
  # A safely recorded failed execution may be reported to the cloud; sign an
  # authorization for exactly this HEAD first.
  authorize_execution_locked "$id" && push_guarded_locked
}

# An existing receipt must agree with the blocked terminal state and the task
# identity. A conflict pauses and keeps every local commit, so a later flush can
# never publish a wrong done notification.
validate_existing_blocked_receipt() {
  local rel=$1 id=$2 out="$REPO/$RECEIPT_SUBDIR/$2.md"
  [ -e "$out" ] || [ -L "$out" ] || return 0
  if [ -f "$out" ] && [ ! -L "$out" ] &&
      [ "$(read_field "$out" 'Task ID')" = "$id" ] &&
      [ "$(read_field "$out" 'Original task')" = "$rel" ] &&
      [ "$(read_field "$out" 'Result status')" = blocked ]; then
    return 0
  fi
  log 'push blocked: the existing receipt disagrees with the blocked state or the task identity; the immutable receipt is not rewritten'
  quarantine_execution "$id"
  return 1
}

# Returns 0 = new receipt, 1 = not needed or an identical one exists,
# 2 = error (never degrade into pushing without the required receipt).
write_blocked_receipt() { # $1=file $2=rel $3=id $4=reason $5=ts [$6=phase]
  local file=$1 rel=$2 id=$3 reason=$4 ts=$5 phase=${6:-before} title out tmp summary
  RECEIPT_REL=''
  [ "$(read_field "$file" Receipt)" = required ] || return 1
  validate_task_identity "$file" "$rel" "$id" || return 2
  RECEIPT_REL="$RECEIPT_SUBDIR/${id}.md"
  out="$REPO/$RECEIPT_REL"
  if [ -e "$out" ] || [ -L "$out" ]; then
    validate_existing_blocked_receipt "$rel" "$id" || return 2
    log "note: a consistent blocked receipt already exists and is kept as is: $RECEIPT_REL"
    RECEIPT_REL=''
    return 1
  fi
  title=$(sed -n 's/^# //p' "$file" | head -n 1) || return 2
  summary='blocked before dispatch; the task was not executed'
  [ "$phase" = after ] && summary='the executor was started and then failed; partial side effects are possible and the task is not complete'
  mkdir -p "$REPO/$RECEIPT_SUBDIR" || return 2
  tmp=$(mktemp "$STATE_DIR/receipt.XXXXXX") || return 2
  {
    printf '# Receipt: %s\n\n' "${title:-$id}" &&
    printf -- '- Task ID: %s\n' "$id" &&
    printf -- '- Original task: %s\n' "$rel" &&
    printf -- '- Result status: blocked\n' &&
    printf -- '- Updated: %s\n' "$ts" &&
    printf -- '- Summary: relay-runner %s: %s\n' "$summary" "$reason" &&
    printf -- '- Artifacts: not verified; check the original task and the local checkout\n' &&
    printf -- '- Next step: the user must verify the cause, the progress and any side effects, then explicitly recover; the cloud side only reports and never continues automatically.\n'
  } >"$tmp" || { rm -f "$tmp"; return 2; }
  # noclobber keeps a writer that ignores the shared lock from being overwritten.
  ( set -C; cat "$tmp" >"$out" ) || { rm -f "$tmp"; return 2; }
  rm -f "$tmp"
  log "wrote blocked receipt: $RECEIPT_REL"
}

# ---------------------------------------------------------------- guarded push
push_guarded() { with_git_lock push_guarded_locked; }

push_guarded_locked() {
  local head base dirty i rc=1 grc=0
  validate_locked_repo || return 1
  dirty=$(git status --porcelain -uall 2>/dev/null) || return 1
  [ -z "$dirty" ] || { log 'push aborted: the working tree is dirty; keeping the scene'; return 1; }
  head=$(git rev-parse HEAD) && base=$(git rev-parse origin/main) || return 1
  if pause_present; then log 'push blocked: a pause marker or blocker is present'; return 1; fi
  unblock_executor_push
  if ! check_execution_locked "$head" || ! validate_pending_protocol "$head" "$base"; then
    log 'push blocked: execution evidence is missing or unresolved, or a receipt does not match'
    write_pause 'execution evidence or a pending receipt failed verification; deleting PAUSED alone does not authorize a push' || log 'error: could not write the pause marker; refusing to push anyway'
    return 1
  fi
  scan_pending_commits "$head" "$base" || grc=$?
  if [ "$grc" != 0 ]; then
    log "push blocked: the output gate did not pass (${GUARD_OUT_ERR:-$GUARD_OUT_PATTERNS})"
    write_pause "output gate did not pass: ${GUARD_OUT_ERR:-$GUARD_OUT_PATTERNS} (${GUARD_OUT_FILES})"
    return 1
  fi
  i=1
  while [ "$i" -le "$PUSH_RETRIES" ]; do
    validate_locked_repo || return 1
    if [ "$(git rev-parse HEAD)" != "$head" ] || [ "$(git rev-parse origin/main)" != "$base" ]; then
      log 'abort: HEAD or origin/main moved after the scan'; return 1
    fi
    pause_present && return 1
    check_execution_locked "$head" || return 1
    # Push the scanned OID, not a HEAD another tool could have moved; never force.
    if git push origin "$head:refs/heads/main" 2>>"$LOG_FILE"; then
      clear_approved_execution_locked "$head" || {
        log 'the remote accepted the push but the execution evidence could not be cleared; keeping the scene for verification'
        write_pause 'the remote received the commits but the execution evidence could not be cleared; compare both OIDs and recover manually' || true
        return 1
      }
      rc=0
      break
    fi
    log "push failed ($i/$PUSH_RETRIES); keeping the local commits"
    [ "$i" -lt "$PUSH_RETRIES" ] && sleep "$PUSH_RETRY_DELAY"
    i=$((i + 1))
  done
  return "$rc"
}

# ---------------------------------------------------------------- pause and locks
pause_present() { [ -e "$PAUSE_FILE" ] || [ -L "$PAUSE_FILE" ]; }

# Never overwrite an existing reason; a directory or a dangling link is a
# blocker too but cannot be reported as a successful write.
write_pause() { # $1=reason (never secret values)
  mkdir -p "$STATE_DIR" || { log 'error: cannot create the state directory for the pause marker'; return 1; }
  if pause_present; then
    log 'an existing pause marker or blocker is kept; its reason is not overwritten'
    [ -f "$PAUSE_FILE" ] && [ ! -L "$PAUSE_FILE" ]
    return $?
  fi
  if ! (
    set -C
    {
      printf 'Paused at: %s\n' "$(now_utc)"
      printf 'Reason: %s\n' "$1"
      printf 'Recovery: verify the unpushed history and the <git-dir>/%s record, inspect origin/main..HEAD in %s, clean the unpushed commits, then delete %s. Deleting PAUSED alone does not authorize a push.\n' "$EXECUTION_DIRNAME" "$REPO" "$PAUSE_FILE"
    } >"$PAUSE_FILE"
  ) 2>/dev/null; then
    log 'error: the pause marker could not be written or was created concurrently; nothing is authorized by it'
    return 1
  fi
  log "pause marker written: $PAUSE_FILE"
  return 0
}

release_tasklock() { # $1=task lock directory; only this one
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  if rmdir "$1" 2>/dev/null; then
    log "released task lock: $1"
  else
    log "note: the task lock could not be released; left for manual verification: $1"
  fi
}

# ---------------------------------------------------------------- executor config
# Read only daemon.agentProfiles from a Paseo config. A missing role is an error;
# the runner never substitutes a different role or provider.
role_lookup() { # $1=role name
  local role=$1 out rc head1
  ROLE_ERR=''
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
    # '-' placeholder: with IFS=tab a leading empty field would be dropped
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
  local id=$1 rel=$2 tasklock=$3 notes allowlist
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
   what the user must do; never present blocked as completion. If the task
   carries "- Receipt: required", also write $RECEIPT_SUBDIR/<ID>.md with the
   same "- Result status:" so the two agree.
5. Commit only this task file and material the task explicitly authorizes.
   Never use git add -A, force-push, rebase, reset or stash; never rewrite other
   commits. Do not modify tasks/README.md or other task files.
   Do NOT git push: the runner records execution evidence, scans your output and
   pushes it only if it is clean.
6. Before Git writes, take the shared lock: run 'git rev-parse --absolute-git-dir'
   in $REPO, then 'mkdir <git-dir>/$GITLOCK_NAME'. If that fails, wait for the
   next opportunity; never delete another process's lock. Release only your own
   lock after committing.
7. Do not modify, load or install credential-related launchd jobs, do not read
   the Keychain, and never print or persist secrets.
8. Release your task lock when finished: 'rmdir $tasklock' — only this lock.
9. If you cannot finish, set blocked with the reason and commit it (do not
   push). Do not leave a half-done state or silently repeat an action with side
   effects.
EOF
}

# With the output gate on, the executor's own pushes are disabled (best effort):
# its Git processes inherit an invalid origin pushurl via GIT_CONFIG_* env, and
# the checkout gets the same pushurl in its local config while the executor runs
# (only when no pushurl is configured; removed again afterwards). The runner's
# own guarded push names the fetch URL explicitly.
GUARD_PUSHURL=relay-guard-push-disabled://
block_executor_push() {
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
  printf '%s\n' GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl \
    GIT_CONFIG_VALUE_0="$GUARD_PUSHURL"
}

launch_paseo() { # $1=task ID $2=cwd $3=prompt
  local id=$1 cwd=$2 prompt=$3 provider_arg desc rc
  local -a args xenv=()
  local _e

  if [ -n "$ROLE_MODEL" ]; then provider_arg="$ROLE_PROVIDER/$ROLE_MODEL"
  else provider_arg="$ROLE_PROVIDER"; fi

  if [ -n "$ROLE_FEATURE_KEYS" ]; then
    log "note: role '$ROLE_NAME' featureValues are not applied by the Paseo CLI (keys=$ROLE_FEATURE_KEYS); using provider defaults"
  fi

  # The prompt is positional and must remain last.
  # With the output gate on, wait for the agent (no --no-wait) so the runner can
  # record execution evidence and inspect its local commits before anything is pushed.
  args=(run); desc=run
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
  local id=$1 rel=$2 cwd=$3 prompt=$4 desc rc
  local -a args=(--task-id "$id") xenv=()
  local _e
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
  mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$MARKER_DIR" 2>/dev/null || true
  rotate_log
  log "──── relay-runner start (pid $$, executor $EXECUTOR, checkout $REPO, guard_wait $GUARD_WAIT)"
  trap 'release_run_lock' EXIT

  if pause_present; then
    log "skip: pause marker present ($PAUSE_FILE)"
    return 0
  fi
  acquire_run_lock || return 1
  # The deployment may create PAUSED between the first check and the lock.
  if pause_present; then
    log "skip: pause marker appeared after the run lock was acquired ($PAUSE_FILE)"
    return 0
  fi
  unblock_executor_push   # recover from an interrupted earlier round
  check_sync_timing || return 0
  repo_ready || return 0

  local tasklock_dir tasks_dir d holders='' oldest age
  tasklock_dir="$GIT_DIR/$TASKLOCK_DIRNAME"
  mkdir -p "$tasklock_dir" 2>/dev/null || { log "skip: cannot create $tasklock_dir"; return 0; }

  tasks_dir="$REPO/$TASKS_SUBDIR"
  [ -d "$tasks_dir" ] || { log "skip: task directory not found: $tasks_dir"; return 0; }

  # One at a time: any task lock (running, or left behind by a crashed agent)
  # stops new dispatch. Locks are never removed by age; an old one is logged.
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

  local file base rel status cwd role_field id updated tasklock found=0
  for file in "$tasks_dir"/*.md; do
    [ -f "$file" ] || continue
    base=$(basename "$file" .md)
    [ "$base" = README ] && continue

    matches_executor "$(read_field "$file" Executor)" || continue
    is_pending "$(read_field "$file" Status)" || continue

    id=$(read_field "$file" 'Task ID')
    updated=$(read_field "$file" Updated)
    if [ -z "$id" ] || [ -z "$updated" ]; then
      log "skip: $base lacks a Task ID or Updated header; not a valid protocol task"
      continue
    fi
    if ! valid_task_id "$id" || [ "$id" != "$base" ] || [ -L "$file" ]; then
      log "skip: $base has an unsafe Task ID ('$id') or its filename and ID differ; nothing is claimed and no lock is taken"
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
      log "skip: cannot acquire the task lock for $base (concurrent or stale lock)"
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

    if ! claim_task "$file" "$rel" "$base"; then
      log 'claim failed; releasing the task lock and ending this round without dispatch'
      rmdir "$tasklock" 2>/dev/null || true
      return 1
    fi

    cwd=$(read_field "$file" 'Target directory')
    # No target directory: pin the executor to the task checkout.
    [ -n "$cwd" ] || cwd=$REPO
    role_field=$(read_field "$file" Role)

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

    # Guard 2: scan the task body; never echo the matched text.
    guard_scan "$file"
    case "$?" in
      0) ;;
      1) log "guard 2 blocked: task body matched sensitive patterns: $GUARD_SCAN_HITS"
         if ! block_task "$file" "$rel" "$base" "Task body matched sensitive patterns: $GUARD_SCAN_HITS"; then
           rmdir "$tasklock" 2>/dev/null || true
           log 'stopping this round: could not record the blocked state'
           return 1
         fi
         rmdir "$tasklock" 2>/dev/null || true
         continue ;;
      *) log "guard 2 could not complete ($GUARD_SCAN_HITS); nothing dispatched"
         if ! block_task "$file" "$rel" "$base" "Task body scan could not complete: $GUARD_SCAN_HITS"; then
           rmdir "$tasklock" 2>/dev/null || true
           log 'stopping this round: could not record the blocked state'
           return 1
         fi
         rmdir "$tasklock" 2>/dev/null || true
         continue ;;
    esac

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

    if [ "$DRY_RUN" != 1 ] && ! begin_execution "$base"; then
      log 'error: cannot persist the execution evidence, so the executor is not started'
      write_pause 'the task was claimed but the execution evidence could not be created; no executor was started, verify and recover manually' || true
      release_tasklock "$tasklock"
      return 1
    fi

    block_executor_push
    local launch_ok=0
    launch_executor "$base" "$rel" "$cwd" "$tasklock" && launch_ok=1
    unblock_executor_push

    if [ "$launch_ok" = 1 ]; then
      if [ "$DRY_RUN" = 1 ]; then
        release_tasklock "$tasklock"
        log '[dry-run] no execution evidence or dispatch marker written'
        return 0
      fi
      if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
        log 'warning: the executor left uncommitted changes; they are never pushed and stay in the checkout until the user inspects them'
      fi
      local finish_rc=0
      complete_execution "$file" "$rel" "$base" || finish_rc=$?
      release_tasklock "$tasklock"
      : >"$MARKER_DIR/$base" 2>/dev/null || log "warning: could not write the dispatch marker $MARKER_DIR/$base"
      if [ "$finish_rc" = 0 ]; then
        log "round complete: verified the final status and safely pushed $base"
        return 0
      fi
      log 'round incomplete: check the remote delivery state; execution evidence and local commits are kept and nothing is retried automatically'
      return 1
    fi

    block_task "$file" "$rel" "$base" 'Executor failed to start or exited non-zero; see the runner log' after
    release_tasklock "$tasklock"
    return 1
  done

  [ "$found" = 1 ] || log 'nothing to do: no pending task opted in with a matching Executor field'
  return 0
}

# RELAY_RUNNER_SOURCE_ONLY=1 loads the functions (for offline tests) without
# running the main flow.
if [ "${RELAY_RUNNER_SOURCE_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
exit $?
