# Agent Relay

Git-backed task handoff between local and cloud AI agents.

One Markdown file per task. Git for transport and history. A webhook wakes the
cloud agent; by default a macOS timer delivers files locally without starting an
AI session. An optional local runner can also claim and execute opted-in local
tasks, so the relay can work automatically in both directions.

[中文说明](README.zh-CN.md) · [Protocol](docs/protocol.md) · [Security](docs/security.md)

## How it works

```text
Local → private Git repo / tasks/to-cloud → webhook → cloud agent
Cloud → private Git repo / tasks/to-local → pull-only macOS sync
                                           → optional runner (opt-in) or human-started local agent
Round-trip (`- Receipt: required`): receiver → tasks/receipts/<direction> → sender continues
```

Each task moves from `pending` to `accepted` to `done` or `blocked`.
The receiving agent writes its result into the same file.
Delivery is not acceptance; acceptance is not completion.

A task marked `- Receipt: required` is a round-trip: when the receiver finishes,
it also writes a short receipt — `tasks/receipts/to-cloud/<ID>.md` after local
work, `tasks/receipts/to-local/<ID>.md` after cloud work — so the sender can
continue without polling. Receipts carry the outcome and one next step; they are
not tasks and grant no new authority. See the protocol for the receipt format and
the `tasks-to-cloud-receipt` wakeup.

No database, model polling loop, or always-running local agent.
This is a reference implementation that an agent can read and use to help its
user deploy the full workflow—not an agent runtime, a one-click hosted service,
or a claim that every provider has been tested. The user supplies repository
access, a supported cloud environment, webhook credentials and required approvals.
Give your agent this repository and ask it to read this README, the protocol and
the setup guide for each endpoint before proposing or making installation changes.

## Automatic relay in both directions

- **Local → cloud** is automatic after a new pending task is pushed: the GitHub
  Actions webhook wakes the configured cloud agent.
- **Cloud → local** arrives through the pull-only timer. By default a human still
  starts the local agent. If you install the optional runner, a to-local task
  that explicitly opts in with `- Executor:` is claimed and dispatched
  automatically. Tasks without that field keep the manual view/takeover flow.
- The runner is off by default. It never fetches or pulls, runs at most one task
  at a time, and refuses dirty, divergent or locked checkouts.
- A dispatch failure is recorded as `blocked` with a reason. The runner never
  retries or substitutes another role/provider, and it never performs
  high-risk actions itself: the dispatched agent must prepare publishing,
  deletion, deployment, permission changes and external messages for approval.

### Safety guards

The runner applies three fail-closed guards (details in
[docs/security.md](docs/security.md)):

1. **Target directory allowlist** — a raw path containing `..` is rejected; the
   real path (symlinks resolved) must be inside the task checkout,
   `RELAY_WORKSPACE_ALLOWLIST`, or an existing project directly under
   `RELAY_PROJECTS_ROOT`.
2. **Task body scan** — before claiming, the task text (all but the validated
   metadata headers) is checked for sensitive patterns such as `.ssh`, private keys,
   `.env`, Keychain, credential/token assignments and upload commands
   (`curl -F`, `scp host:`...). A hit marks the task `blocked` without starting
   the executor and without echoing the text.
3. **Output gate** (`RELAY_GUARD_WAIT=1`, default) — the executor only commits;
   the runner waits, scans every commit it would push (messages and added
   lines) for likely secrets, and pushes only if clean. A hit records `blocked` in a local-only
   commit, writes the `PAUSED` marker and pushes nothing.

## What's included

- A shared task protocol and local/cloud skills, including optional round-trip
  receipts.
- A pull-only Git sync script and macOS launchd installer (300 seconds).
- An optional local auto-relay runner, plist template and installer flag.
- An optional read-only receipt notifier (`scripts/macos/receipt-notify.sh`) for
  new cloud receipts; it only raises macOS notifications.
- A GitHub Actions webhook template with separate pending-task and receipt events.
- A Grok Bot integration guide and receiver prompt.
- Isolated Git/mock tests; no real webhook or agent required.

## Setup

1. Create a **separate, preferably private task repository**, with branch `main`.
   Do not put real tasks in this public source repository.
2. Copy `docs/protocol.md` into that repository as `tasks/README.md`.
   Create `tasks/to-cloud/`, `tasks/to-local/`, `tasks/receipts/to-cloud/` and
   `tasks/receipts/to-local/` with empty `.gitkeep` files.
   Commit and push this initial layout.
3. Clone the task repository on each endpoint. Use a dedicated cloud checkout
   outside any workspace managed by another auto-commit process.
4. Follow [macOS setup](docs/setup-local-macos.md) and
   [cloud / Grok setup](docs/setup-cloud-grok.md).
   The local installer is pull-only unless you pass `--with-runner` or
   `--with-receipt-notify`.
5. Install the appropriate `skills/local/agent-relay/` or
   `skills/cloud/agent-relay/` in your agent's skill directory.
   Configure the task checkout path in that agent's instructions.
6. Run the harmless acceptance procedure in [architecture](docs/architecture.md).
   Test the optional runner with `RELAY_RUNNER_DRY_RUN=1` first.

Say “hand this task to the cloud agent”, “show incoming tasks without accepting”,
or “take over task ID”. Drafting is not permission to publish, and adding
`- Executor:` is permission to dispatch a local agent only when the user says so.

## Important limits

The timer runs approximately every five minutes while the user session is active;
sleep, network failure, dirty worktrees and locks can delay delivery.
Cloud webhook notifications are at-least-once hints, not exactly-once execution.
Git locks coordinate only participating processes. The runner depends on the
pull-only timer, keeps a task lock until the dispatched agent releases it, and
does not verify the final result. A stale task lock or an abandoned `accepted`
task stalls the queue until a human inspects it.

The original private deployment was tested in both directions. This extracted
public candidate has separate validation: see [validation](docs/validation.md).
Do not treat the original deployment's success as proof of a fresh Grok setup.
The runner tests use a mocked executor; they are not a live end-to-end proof.

Public v1 uses English `- Status:` metadata. It is not a drop-in replacement
for earlier private deployments using localized metadata. Do not mix their
workflow filters and task templates.

## Development

```sh
bash tests/test-sync.sh
bash tests/test-notify.sh
bash tests/test-relay-runner.sh
bash tests/test-relay-guard.sh
bash tests/test-receipt-notify.sh
```

Git and Bash are sufficient for these tests. The runner test uses a fake
executor and disposable Git repositories; the receipt test uses a fake
notification binary. macOS is required for launchd.
No package installation is needed. MIT licensed; see [LICENSE](LICENSE).
