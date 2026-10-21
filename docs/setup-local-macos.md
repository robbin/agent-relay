# macOS setup

Requirements: an active macOS user session, Git, a private task repository on
GitHub with main branch, and noninteractive fetch authentication through SSH or
the system credential manager. Configure Git identity for agent-created commits.

1. Clone the **task repository**, not this source repository, to a dedicated path.
   Initialize tasks/README.md and the two task directories as described in README.
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
   install.
4. Copy skills/local/agent-relay into your host's user skill directory.
   Tell the agent its role is local, the absolute task checkout path, expected
   repository identity and branch main. Host skill discovery is host-specific;
   explicit reading of SKILL.md is a valid fallback.
5. Ask to view incoming tasks, then explicitly take over a chosen task.

Installed files:
- `~/Library/LaunchAgents/io.agent-relay.sync.plist`
- `~/Library/Application Support/agent-relay/sync.sh`
- `~/Library/Logs/agent-relay/sync.log` and `sync-error.log`

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
- The executor must be able to commit and push through the system credential
  helper noninteractively; the agent does that itself, not the runner.

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
- `RELAY_MIN_SECONDS_AFTER_SYNC` (120), `RELAY_MAX_SYNC_AGE` (1500) — timing gate.
- `RELAY_RUNNER_DRY_RUN=1` — log the intended action without changing files,
  starting the task executor or leaving a task lock. Read-only probes such as
  the provider availability check may still run.

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
- `<git-dir>/agent-relay-git.lock/` and `<git-dir>/agent-relay-task-locks/<ID>/`

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

The runner processes one task per trigger. It keeps the task lock until the
dispatched agent releases it; while any task lock exists, later rounds do not
dispatch. It never deletes Git or task locks, even when they look old. If an
agent disappears, the task stays accepted with its lock and requires explicit
recovery after checking side effects. A blocked task is never retried or
replaced, and dispatch failure is recorded as blocked with a reason appended at
the end of the file. Keep `## Result` as the last section in task files; a
blocked note appended after later sections would land in the wrong place.

The runner does not wait for completion and does not verify the final result.
Uninstall removes both jobs and scripts; it preserves the checkout, logs, state
directory and locks.

The installer supports one task checkout per user. Multiple checkout scheduling,
other OS service managers and remote executor hosts are out of scope.
