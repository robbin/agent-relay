#!/bin/bash
# relay-runner.sh — optional local auto-relay executor (launchd: io.agent-relay.runner)
#
# Usage: bash relay-runner.sh ABSOLUTE_CHECKOUT
#
# launchd calls this every 300 seconds. It scans <checkout>/tasks/to-local/ for
# pending tasks whose `- Executor:` field explicitly matches the configured
# executor adapter, claims at most one, dispatches it to that adapter, and exits
# without waiting for the work to finish.
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

# Optional identity check for origin; empty disables the check.
EXPECTED_ORIGIN=${RELAY_EXPECTED_ORIGIN:-}

MIN_SECONDS_AFTER_SYNC=${RELAY_MIN_SECONDS_AFTER_SYNC:-120}
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

# Allow: the task checkout (or a directory inside it) and each allowlist entry.
dir_allowed() {
  local candidate repo_real entry base
  candidate=$(resolve_dir "$1") || return 1
  repo_real=$(resolve_dir "$REPO") || return 1
  if [ "$candidate" = "$repo_real" ]; then return 0; fi
  case "$candidate" in "$repo_real"/*) return 0 ;; esac
  local IFS=:
  for entry in $WORKSPACE_ALLOWLIST; do
    [ -n "$entry" ] || continue
    base=$(resolve_dir "$entry") || continue
    if [ "$candidate" = "$base" ]; then return 0; fi
    case "$candidate" in "$base"/*) return 0 ;; esac
  done
  return 1
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
  local id=$1 rel=$2 tasklock=$3 notes allowlist
  notes=$ROLE_NOTES
  [ -n "$notes" ] || notes='No extra role notes. Act as a careful general-purpose executor.'
  allowlist=$WORKSPACE_ALLOWLIST
  [ -n "$allowlist" ] || allowlist='none configured (the task checkout only)'

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
6. Before Git writes, take the shared lock: run 'git rev-parse --absolute-git-dir'
   in $REPO, then 'mkdir <git-dir>/$GITLOCK_NAME'. If that fails, wait for the
   next opportunity; never delete another process's lock. Release only your own
   lock after committing and pushing.
7. Do not modify, load or install credential-related launchd jobs, do not read
   the Keychain, and never print or persist secrets.
8. Release your task lock when finished: 'rmdir $tasklock' — only this lock.
9. If you cannot finish, set blocked with the reason and commit/push it. Do not
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
  args=(run --no-wait)
  desc="run --no-wait"
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
  if "$EXECUTOR_BIN_PATH" "${args[@]}" >>"$LOG_FILE" 2>&1; then
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
  local rc
  if ( export RELAY_TASK_ID="$id" RELAY_TASK_FILE="$rel" RELAY_TASK_CWD="$cwd" \
           RELAY_TASK_ROLE="$ROLE_NAME"; printf '%s\n' "$prompt" ) \
       | "$EXECUTOR_BIN_PATH" "${args[@]}" >>"$LOG_FILE" 2>&1; then
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
  log "──── relay-runner start (pid $$, executor $EXECUTOR, checkout $REPO)"
  trap 'release_git_lock; release_run_lock' EXIT

  if [ -f "$PAUSE_FILE" ]; then
    log "skip: pause marker present ($PAUSE_FILE)"
    return 0
  fi
  acquire_run_lock || return 1
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

    if ! claim_task "$file" "$rel" "$base"; then
      log 'claim failed; releasing the task lock and ending this round without dispatch'
      rmdir "$tasklock" 2>/dev/null || true
      return 1
    fi

    cwd=$(read_field "$file" 'Target directory')
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
        log "target directory is outside the allowlist: $cwd"
        if ! block_task "$file" "$rel" "$base" "Target directory is outside the configured allowlist: $cwd"; then
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

    if launch_executor "$base" "$rel" "$cwd" "$tasklock"; then
      if [ "$DRY_RUN" = 1 ]; then
        rmdir "$tasklock" 2>/dev/null || true
        log '[dry-run] no marker written; task lock released'
      else
        : >"$MARKER_DIR/$base" || log "warning: could not write dispatch marker $MARKER_DIR/$base"
        log 'round complete: dispatched one task; the task lock stays until that agent releases it'
      fi
      return 0
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
