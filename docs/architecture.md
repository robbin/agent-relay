# Architecture and acceptance

The source repository distributes code and documentation. A separate private
task repository carries live tasks. Both endpoints read its tasks/README.md.

By default the local timer only fetches and fast-forwards, and a human starts
the local session. An optional local runner can instead claim and dispatch
to-local tasks that explicitly opt in with a matching `- Executor:` field. It is
off by default and never touches tasks that do not carry that field.

The cloud webhook wakes an already configured agent routine; it is not an agent
runtime and does not execute Markdown by itself.

Public v1 uses a dedicated cloud checkout and agent-owned narrow commits for
claims/results. It does not ship or require the original private deployment's
whole-workspace auto-commit daemon. This is a deliberate deployment difference.

## Components

```text
Local sender ── tasks/to-cloud ──> Git ──> webhook ──> cloud agent (claims/executes)
Local timer (pull-only ff) <── tasks/to-local ── cloud sender or agent
Optional local runner (opt-in `- Executor:`) ──> local executor agent (claims/executes)
Round-trip (`- Receipt: required`): receiver ──> tasks/receipts/to-cloud ──> receipt webhook ──> cloud agent continues
                                    cloud ──> tasks/receipts/to-local ──> optional receipt notifier (macOS notification only)
```

- `scripts/macos/sync.sh` (launchd `io.agent-relay.sync`): fetch plus
  fast-forward only. It does not commit, push, start an agent or execute tasks.
- `scripts/macos/relay-runner.sh` (launchd `io.agent-relay.runner`, optional):
  reads what sync delivered, claims at most one eligible pending to-local task,
  pushes accepted, dispatches to a configured executor and exits. It never
  fetches, pulls, rebases, stashes or force-pushes.
- `scripts/macos/receipt-notify.sh` (launchd `io.agent-relay.receipt-notify`,
  optional): read-only watcher of `tasks/receipts/to-local/`. It notifies once
  per new receipt and never starts an agent. Receipts to the cloud are pushed by
  an agent and wake the cloud through the webhook template instead.
- `install.sh` installs the timer; `--with-runner` also installs the runner and
  `--with-receipt-notify` the receipt notifier.
  `uninstall.sh` removes all installed jobs and leaves repository, logs, runner
  state, receipt seen list and task locks intact.

The runner serializes work with a private run lock, the shared Git lock for its
short claim/blocked commits, and the per-task lock used by manual takeover. It
refuses to act when the checkout is dirty, off main, diverged from origin/main,
has an unfinished Git operation, has an unreleased task lock, or when the sync
log is too recent or too old. These checks preserve the local Git scene rather
than repairing it automatically.

## Harmless end-to-end acceptance

Use a disposable private task repository and explicit user authorization.

1. Local sends one complete pending to-cloud task requesting a fixed phrase in
   Result, allowing edits only to that task. Verify automatic cloud receipt,
   accepted claim, done result and remote commit.
2. Confirm the result-only push did not send another webhook.
3. Cloud sends one equally constrained to-local task without an Executor field.
   Leave the Mac timer alone; observe OK updated. Before takeover, the task must
   remain pending.
4. Ask the local agent to view only; verify no state change.
5. Explicitly take over; verify accepted was pushed before execution and done
   afterward. Check result on the remote.
6. If the optional runner was installed, first run it once with
   `RELAY_RUNNER_DRY_RUN=1` and confirm it reports the intended command without
   changing files. Then authorize exactly one harmless to-local task with
   `- Executor:` matching the configured adapter and a `- Target directory:`
   inside the configured allowlist. Confirm: accepted was pushed before
   dispatch, a dispatch marker and task lock existed, the executor wrote Result,
   updated done/blocked, and released its own task lock. Do not use a task with
   external side effects for this check.
7. Confirm that a to-local task without `- Executor:` is still untouched by the
   runner after this test.
8. If round-trip receipts interest you, send one harmless task with
   `- Receipt: required` and verify the receiver wrote the receipt in the other
   direction, that it carries the outcome and one next step, and that a receipt
   for cloud work woke the cloud agent once (the local notifier, if installed,
   raises a macOS notification only). Confirm a repeated tick does not notify
   again.

Record commits, timestamps and which actions were manual. Do not reuse IDs.
A file existing is not proof of skill discovery; test natural-language routing
separately. Do not generate more test tasks without authorization.

A mocked runner test is not a live executor integration test. Real dispatch
starts a real local agent with host permissions; review the task, allowlist,
role and executor configuration before enabling the job.
