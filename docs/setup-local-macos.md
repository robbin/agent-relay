# macOS setup

Requirements: an active macOS user session, Git, a private task repository on
GitHub with main branch, and noninteractive fetch authentication through SSH or
the system credential manager. Configure Git identity for agent-created commits.

1. Clone the **task repository**, not this source repository, to a dedicated path.
   Initialize tasks/README.md, the two task directories and the two receipt
   directories as described in README.
2. From this source checkout, test a single pull:
   ```sh
   bash scripts/macos/sync.sh /absolute/path/to/tasks git@github.com:OWNER/TASKS.git
   ```
   The second argument must exactly match `git remote get-url origin`.
   It is an identity check, not a credential. Never embed tokens in URLs.
3. Install the timer:
   ```sh
   bash scripts/macos/install.sh /absolute/path/to/tasks
   ```
   Installation starts a pull immediately, then every 300 seconds. It does not
   start an agent, commit or push. The installer refuses to overwrite an existing
   install. Pass `--with-runner` for the optional executor and/or
   `--with-receipt-notify` for the optional receipt notifier.
4. Copy skills/local/agent-relay into your host's user skill directory.
   Tell the agent its role is local, the absolute task checkout path, expected
   repository identity and branch main. Host skill discovery is host-specific;
   explicit reading of SKILL.md is a valid fallback.
5. Ask to view incoming tasks, then explicitly take over a chosen task.

Installed files:
- `~/Library/LaunchAgents/io.agent-relay.sync.plist`
- `~/Library/Application Support/agent-relay/sync.sh`
- `~/Library/Logs/agent-relay/sync.log` and `sync-error.log`
- With the optional flags: `io.agent-relay.runner.plist` / `relay-runner.sh` and
  `io.agent-relay.receipt-notify.plist` / `receipt-notify.sh`

Check:
```sh
launchctl print gui/$(id -u)/io.agent-relay.sync
tail -n 30 "$HOME/Library/Logs/agent-relay/sync.log"
```

OK updated means a fast-forward happened, not execution. OK unchanged is normal.
SKIP means the branch, worktree, index, lock or outgoing commits need attention.
ERROR is also written to sync.log; an empty stderr log does not prove success.
Fetch has connection/low-speed limits, not a hard deadline for the whole process.

Uninstall with `bash scripts/macos/uninstall.sh`. It removes the installed timers
and scripts, not the task checkout, logs, runner state or task locks. Do not
install this candidate alongside another process managing the same checkout.
To update, uninstall then install; review new source before replacing the
installed copy.

## Optional local auto-relay runner

The default timer is pull-only. You may additionally install the opt-in runner,
which claims and dispatches pending to-local tasks **only when the task carries a
matching `- Executor:` field**. Tasks without that field still wait for manual
view/takeover. Automatic dispatch starts a real local agent; review the security
section and test in a disposable repository first.

Requirements for the runner:
- The pull-only timer above is already running (the runner never fetches/pulls).
- An executor CLI available under the launchd PATH (`~/.local/bin`,
  `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`), or an absolute
  `RELAY_EXECUTOR_BIN`. The default adapter expects the Paseo CLI (`paseo`).
- The executor must be able to create local commits. It must not push: the
  runner pushes the scanned commit with the credential helper. Fetches still
  come only from the pull-only timer.

Install both jobs in one step (the installer still refuses to overwrite):
```sh
bash scripts/macos/install.sh /absolute/path/to/tasks --with-runner \
  --runner-env RELAY_WORKSPACE_ALLOWLIST=/absolute/project-a:/absolute/project-b \
  --runner-env RELAY_DEFAULT_PROVIDER=PROVIDER/MODEL \
  --runner-env RELAY_DEFAULT_THINKING=THINKING_OPTION
```

`--runner-env NAME=VALUE` is optional and repeatable. To add the runner to an
existing pull-only installation, run `uninstall.sh` first and reinstall with the
flag; the installer does not modify a live installation in place. The installer
pins `HOME`, `PATH`, `LANG`, `LC_ALL`, `RELAY_LOG`, `RELAY_SYNC_LOG`,
`RELAY_STATE_DIR`, `RELAY_EXPECTED_ORIGIN` and the checkout argument; those names
are rejected on the command line. Any value with a newline is rejected.

Common runner settings (all optional):
- `RELAY_EXECUTOR=paseo|command` — adapter, default `paseo`. A `command` adapter
  needs `RELAY_EXECUTOR_BIN` pointing to your wrapper; it receives
  `--task-id <ID>`, optional `--cwd <dir>` and optional `--role <name>`, with the
  prompt on stdin, and its exit status decides dispatch success.
- `RELAY_EXECUTOR_BIN=/absolute/path` — executor binary; default `paseo` from PATH.
- `RELAY_WORKSPACE_ALLOWLIST=/abs/a:/abs/b` — directories the executor may use.
  Empty means the task checkout only. Out-of-scope tasks become blocked.
- `RELAY_DEFAULT_PROVIDER` / `RELAY_DEFAULT_THINKING` — used when a task has no
  `- Role:`. Empty lets the executor choose its own defaults.
- `RELAY_PASEO_WORKSPACE` — optional workspace identifier passed to the CLI.
- `RELAY_PASEO_CONFIG` — optional role preset file (read-only, default
  `~/.paseo/config.json`). Only `daemon.agentProfiles` is read, by exact name.
- `RELAY_PROJECTS_ROOT=/abs/projects` — optional: any existing first-level
  directory under it (and its subdirectories) is allowed; the root itself is not.
- `RELAY_GUARD_WAIT` — must be `1` (the default). Any other value is refused at
  startup: without the final exit status the runner cannot issue a push
  authorization, so asynchronous dispatch is not offered.
- `RELAY_GUARD_BLOB_MAX` (1048576) — pending blobs larger than this are refused.
- `RELAY_GUARD_BLOB_ALLOW` — colon-separated shell globs of paths whose large or
  binary content may be pushed without content scanning (`docs/img/*.png`).
  Empty by default: large and binary changes fail closed.
- `RELAY_MIN_SECONDS_AFTER_SYNC` (30), `RELAY_MAX_SYNC_AGE` (1500) — timing gate.
- `RELAY_PUSH_RETRIES` (3), `RELAY_PUSH_RETRY_DELAY` (10) — guarded push retries.
- `RELAY_GITLOCK_TRIES` (20), `RELAY_GITLOCK_SLEEP` (3) — wait for the shared
  Git lock; after that the round changes, commits and pushes nothing.
- `RELAY_STALE_TASK_LOCK_SECONDS` (1800) — only used to note an old task lock in
  the log; locks are never removed by the runner.
- `RELAY_MAX_LOG_BYTES` (10485760) — the runner log is truncated in place.
- `RELAY_RUNNER_DRY_RUN=1` — log the intended action without changing files,
  starting the task executor or leaving a task lock or execution record.
  Read-only probes such as the provider availability check may still run.

Task opt-in fields (English metadata, see protocol):
```markdown
- Executor: paseo
- Role: optional-preset-name
- Target directory: /absolute/path
```

The reference plist is `scripts/macos/relay-runner.plist.template`; the installer
generates the real plist with plutil rather than copying the template.

Runner state and logs:
- `~/Library/LaunchAgents/io.agent-relay.runner.plist`
- `~/Library/Application Support/agent-relay/relay-runner.sh`
- `~/Library/Logs/agent-relay/runner.log`
- `~/Library/State/agent-relay/runner/` — run lock, dispatch markers, temp files
- `~/Library/State/agent-relay/runner/PAUSED` — create to pause future dispatches
- `<git-dir>/agent-relay-git.lock/`, `<git-dir>/agent-relay-task-locks/<ID>/`
- `<git-dir>/agent-relay-execution/` — local execution evidence (`owner`,
  `task-id`, `base`, `approved-head`, or `hold/` when an operator must look)

Check:
```sh
launchctl print gui/$(id -u)/io.agent-relay.runner
tail -n 30 "$HOME/Library/Logs/agent-relay/runner.log"
```

Test without dispatching. Repeat the same `RELAY_*` settings you installed,
because a manual shell does not inherit the launchd environment:
```sh
RELAY_RUNNER_DRY_RUN=1 \
RELAY_WORKSPACE_ALLOWLIST=/absolute/project-a:/absolute/project-b \
RELAY_EXPECTED_ORIGIN=git@github.com:OWNER/TASKS.git \
bash "$HOME/Library/Application Support/agent-relay/relay-runner.sh" /absolute/path/to/tasks
```

The runner processes one task per trigger. A round is:
`pause/sync/repository gates → claim (accepted, narrow commit+push) → target
directory, body, executor, role and provider checks → local execution evidence →
dispatch and wait → verify the terminal state and the receipt pair → guarded push`.

It never deletes Git, task or run locks, even when they look old, and it never
reclaims a run lock whose pid looks dead: a missing, empty or dead pid does not
prove that no executor is still running. While any task lock exists, later
rounds do not dispatch. A blocked task is never retried or replaced; the runner
appends the reason to the task file and, for `- Receipt: required` tasks, writes
`tasks/receipts/to-cloud/<ID>.md` stating whether the block happened before
dispatch or after the executor had already run.

After the executor exits, the runner accepts only `done` or `blocked` plus a
consistent receipt, signs an authorization for exactly that HEAD and pushes that
exact commit. Anything else keeps the local commits, writes `PAUSED` and leaves
`<git-dir>/agent-relay-execution/` (with `hold/` when an operator must verify)
for the next inspection. Deleting `PAUSED` does not delete that evidence and does
not authorize a push.

Recovery checklist after `PAUSED`:
1. `git -C <checkout> log --oneline origin/main..HEAD` and
   `git -C <checkout> diff origin/main..HEAD` — nothing unpublished is
   automatically trusted.
2. `ls <git-dir>/agent-relay-execution/` — was an executor started, was a HEAD
   approved, is a `hold/` marker present?
3. Compare the remote task and receipt with the local ones; verify any side
   effect the run could have had.
4. Resolve or discard the local commits and the execution evidence explicitly,
   then delete `PAUSED`.

A stale run lock (`~/Library/State/agent-relay/runner/run.lock/`) and stale task
locks (`<git-dir>/agent-relay-task-locks/<ID>/`) are recovered the same way:
confirm no executor is running, then remove the specific lock by hand. Keep
evidence first, then fix the state, and only then remove the pause reason you
verified. Never clear a lock merely because it is old.

Recovery table (all rows require the user's explicit go-ahead and the shared Git
lock for any Git write):

| State or log text | Meaning | Manual step |
| --- | --- | --- |
| `cannot persist the execution evidence`, remote `accepted` | claim succeeded, evidence creation failed, executor never started | verify log, permissions, disk and leftovers; decide to recover or close; never re-run automatically |
| `execution evidence is missing or unresolved`, `hold` | unknown exit result, a conflict, or an unverified task change | inspect the full local history, task, receipts and real side effects; fix or accept; never fake `approved-head` |
| `the remote received the commits but the execution evidence could not be cleared` | delivery may have succeeded; do not treat it as "not executed" | fetch, compare remote OID/task/receipt, then clean the leftovers and the matching `PAUSED` |
| `HEAD equals origin/main but execution evidence remains` | interrupted or incomplete cleanup; the runner paused | decide unexecuted / executed / delivered first; do not just delete the record |
| `working tree or index is dirty`, `round incomplete` | the executor may have left uncommitted material or an unfinished state | review committed and uncommitted content and side effects; no automatic stash/reset/commit |
| `the run lock exists or cannot be created` | a live process, an initialization window, a restart/SIGKILL leftover or a permission problem | check the real process, pid, task and execution records; remove only the verified leftover lock |
| `behind or diverged` | the ancestry needed for a safe push does not hold | fetch and review both sides by hand; no force push, no automatic rebase |
| an existing pause marker or blocker | files, directories and dangling symlinks all block; the original reason is kept | find who created it and why; never overwrite a deployment marker; check the separate execution evidence |
| `RELAY_GUARD_BLOB_ALLOW` in effect | the listed large/binary paths were pushed without content scanning | treat those paths as manually trusted and keep the glob list reviewable |

Do not exercise error paths by running the full script against a production
repository: use `RELAY_RUNNER_DRY_RUN=1` or the offline tests. Pointing
`RELAY_RUNNER_SOURCE_ONLY=1` at the script only loads its functions for tests; it
is not a launchd setting.
Uninstall removes all installed jobs and scripts; it preserves the checkout, logs, state
directory (including the receipt seen list), execution evidence and locks.

## Optional receipt notifier

For round-trip tasks (`- Receipt: required`), the cloud agent writes
`tasks/receipts/to-local/<ID>.md` when it finishes local work. The optional
notifier watches that directory after the pull-only timer delivers the files and
raises one macOS notification per new receipt. It never fetches, commits, pushes,
starts an agent or edits the checkout, so it costs no model usage.

```sh
bash scripts/macos/install.sh /absolute/path/to/tasks --with-receipt-notify
```

It can be combined with `--with-runner`. To add it to an existing installation,
run `uninstall.sh` first and reinstall with the flag.

State, logs and settings:
- `~/Library/LaunchAgents/io.agent-relay.receipt-notify.plist` (300 seconds,
  RunAtLoad true so the first run records existing receipts as seen)
- `~/Library/Application Support/agent-relay/receipt-notify.sh`
- `~/Library/Application Support/agent-relay/receipts-seen.txt` — seen IDs
- `~/Library/Logs/agent-relay/receipt-notify.log` — one line per decision;
  `receipt-notify-error.log` holds launchd stdout/stderr
- `RELAY_STATE_DIR`, `RELAY_LOG` and `RELAY_OSASCRIPT_BIN` override the state
  directory, log file and notification binary (default `/usr/bin/osascript`)

Check:
```sh
launchctl print gui/$(id -u)/io.agent-relay.receipt-notify
tail -n 30 "$HOME/Library/Logs/agent-relay/receipt-notify.log"
```

The first run after installation only marks existing receipts as seen and never
notifies. A notification that fails (for example because notifications are muted
or the session is not interactive) is logged and retried on the next tick; it is
marked seen only after a successful notification. Notifications are hints only:
the receipt file and the original task remain the source of truth, and the timer
may deliver a receipt up to one sync interval later. The reference plist is
`scripts/macos/receipt-notify.plist.template`; the installer generates the real
plist with plutil rather than copying the template.

The installer supports one task checkout per user. Multiple checkout scheduling,
other OS service managers and remote executor hosts are out of scope.
