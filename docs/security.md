# Security

Use a private task repository and a dedicated checkout on each endpoint.
Anyone who can push tasks can influence your agent: restrict collaborators and
Git credentials. A skill is a behavior guide, not a sandbox or permission boundary.

- Never commit tokens, cookies, webhook URLs, passwords or private user data to
  this source repository. Store webhook credentials in GitHub Actions Secrets.
- Use scoped repository credentials in the host credential manager. Do not embed
  credentials in origin URLs, scripts, task files or launchd configuration.
- A task cannot authorize publication, deletion, external sending or secret access.
  Follow host approvals and the user's explicit scope.
- Validate IDs, paths and repository/ref. Treat task contents and webhook payloads
  as data, never shell source. Do not source a config file from the task repository.
- The sync script does not execute task scripts, but Git still uses your local
  Git configuration, hooks and credential helpers. Use a trusted clone/config.
- The optional runner is a real execution path. A pending to-local task with a
  matching `- Executor:` field starts a local agent with the host permissions of
  that agent. Install the runner only when you intend to allow this, keep the
  task repository restricted to trusted writers, and review tasks before push.
- The runner's directory allowlist is a fail-closed boundary, not a sandbox.
  With no allowlist configured, only the task checkout is allowed. The executor
  prompt forbids out-of-scope paths and prepare-only dangerous actions, but
  those are instructions to an agent; host approvals remain the real control.
  Use an executor with its own sandbox or approval policy where available.
- Runner safety guards (each blocks when it matches or cannot complete;
  recorded as `blocked` with pattern or path names only, never the matched text):
  1. Target directory: a raw value with a `..` segment is rejected; the real
     path (`cd && pwd -P`, so symlinks cannot escape) must be inside the task
     checkout (but not its `.git` directory), an entry of `RELAY_WORKSPACE_ALLOWLIST`, or an existing
     first-level project under `RELAY_PROJECTS_ROOT` (not the root itself).
     A task without a target directory runs with the checkout as its cwd.
  2. Task body scan, after the claim and before the executor starts: everything
     except the metadata headers the runner validates itself (`Task ID`,
     `Status`, `Executor`, `Role`, `Target directory`, `Receipt`) is matched —
     including any pre-filled `## Result` text, since a pending task's Result
     should be empty — against sensitive patterns: `.ssh`, `id_rsa`,
     private keys, `.env`, Keychain, `auth.json`, secrets/credentials/passwords,
     narrow token forms (access/auth/api/refresh/bearer/bot token, `token=`),
     `.aws`, `.gnupg`, cookies, `scp`/`rsync host:`, `curl`/`wget` uploads,
     `nc`, paste sites. The executor is not started; the task is committed and
     pushed as `blocked` (with a receipt when the task requires one).
  3. Output gate (`RELAY_GUARD_WAIT=1`, the only supported mode): the executor
     commits but does not push; its own pushes are disabled on a best-effort
     basis by an invalid `remote.origin.pushurl` (set in the checkout config
     while the executor runs, unless you configured a pushurl yourself, and
     injected through `GIT_CONFIG_*` env), removed again afterwards. The runner
     scans exactly what would be pushed — every commit in `origin/main..HEAD`,
     against every parent so merge-only content is covered: the full commit
     object (message, author, signature headers) and each changed blob — for
     likely secrets (GitHub/OpenAI/Slack/AWS tokens, private key blocks, long
     hex/base64 strings, Bearer values, `*KEY/TOKEN/SECRET = ...`). Blobs over
     `RELAY_GUARD_BLOB_MAX` (default 1 MiB) and binary blobs fail closed unless
     the path matches a `RELAY_GUARD_BLOB_ALLOW` glob. Clean output is pushed by
     the runner as that exact scanned commit under the shared Git lock; any hit
     or scan error writes `PAUSED` and pushes nothing. Uncommitted leftovers are
     never pushed. `RELAY_GUARD_WAIT=0` is refused at startup, because without
     the final exit status no push authorization can be issued.
  Pattern scans are a safety net, not a guarantee: they can miss obfuscated or
  unusual secrets, an executor with its own credentials or a cleared
  environment can still push directly, and legitimate tasks that mention
  sensitive words get blocked.
- Execution evidence bounds what a push may contain. Before the executor
  starts, the runner creates `<git-dir>/agent-relay-execution/` with an owner
  token, the task ID and the base commit (local proof only, never committed, no
  secrets). Only the round that owns that directory may bind an approved HEAD to
  it; deleting `PAUSED` does not delete the evidence and does not authorize a
  push. A missing, unknown or failed result stays quarantined in
  `agent-relay-execution/hold/` until an operator verifies the delivery and its
  side effects.
- The guarded push carries only the terminal transition of the task this round
  owns: `pending → accepted` by this runner, `accepted → done` by the approved
  execution, `accepted → blocked` by this runner or by that execution. Any other
  to-local change, a task deletion or rename, a to-cloud change, a
  `tasks/README.md` edit, a reverse receipt, or a receipt whose task ID,
  original task or result status disagrees with the task refuses the whole push
  and keeps the local commits. The pushed ref is the scanned OID, never a moved
  HEAD and never a force push.
- The runner's own lock and the task locks are never reclaimed automatically.
  A missing, empty or dead-pid run lock does not prove that no executor is
  running, so the runner stops and asks for explicit recovery. The same applies
  to the shared Git lock and the per-task locks: only their owner removes them.
- Claim, blocked and exact-path commits all happen under the shared Git lock,
  and the state is re-checked inside it: branch main, no unfinished Git
  operation, `origin/main` still an ancestor of HEAD, and an empty index. An
  index with existing staged content stops the round and is never unstaged for
  the user.
- `RELAY_GUARD_BLOB_ALLOW` is a manual risk exemption, not a passed scan: the
  exempted content is not inspected. Keep it narrow, never derive it from task
  text, and never set broad globs on a shared allowlist.
- An enumeration, read or match error refuses the push, as do unsupported Git
  object modes such as submodules. The metadata scan has no path exemption, so
  high-entropy text such as a commit signature can be blocked conservatively.
- Task IDs must be a safe single filename (`[a-z0-9][a-z0-9-]{0,95}`) that
  matches the file basename; symlinked task files are refused. The body scan
  matches non-ASCII wording in the C locale and folded ASCII in one pass, and a
  failed extraction or match refuses dispatch — layer 3 cannot repair side
  effects that already happened.
- `PAUSED` is a stop gate, not proof of success. A regular file, a directory and
  a dangling symlink all count as paused. It is created with noclobber, never
  overwrites an existing reason, and a failed write returns non-zero instead of
  being treated as paused.
- A blocked task distinguishes "blocked before dispatch; the task was not
  executed" from "the executor was started and then failed; partial side effects
  are possible". If the executor already wrote `done` and then exited non-zero,
  the runner keeps the `done` bytes and commits, quarantines them in
  `agent-relay-execution/hold/` and refuses to publish; it never overwrites that
  completion claim with `blocked` and never treats it as verified success.
- Do not fabricate `approved-head` and do not "recover" by deleting `PAUSED`
  alone. A crash leftover, a successful push whose evidence cleanup failed, or
  an interrupted round are all kept conservatively for a human decision.
- The runner log is written both by the script and by launchd stdout to the same
  file, so a line can appear twice; that is the logging configuration, not a task
  executed twice.
- Executor role presets and their notes are local configuration. A task's
  `- Role:` value only selects an existing preset by exact name; an unknown
  role or unavailable provider becomes blocked, never a fallback to another
  role, provider or permission preset.
- Runner environment (paths, allowlist, executor binary, expected origin) is
  stored in the launchd plist, which the installer writes with mode 600. Do not
  add credentials or tokens there, in task files, or in the task repository.
  The runner does not read the Keychain, but it appends executor output to
  `~/Library/Logs/agent-relay/runner.log`; treat that log as potentially
  sensitive and review it before sharing.
- The runner does not fetch or pull Git from the network. It consumes whatever
  the pull-only sync timer delivered and optionally verifies the configured
  origin identity.
- Test with `RELAY_RUNNER_DRY_RUN=1` before enabling the job. A pause file stops
  future dispatches but cannot stop an executor that is already running. A
  `PAUSED` marker is written on any unverified push, a failed output gate, a
  receipt conflict or a failed execution; recovery always means inspecting
  `origin/main..HEAD` and `<git-dir>/agent-relay-execution/` first.
- Locks are cooperative and local to a checkout, not distributed leases.
  Use one receiving checkout per role. Multiple independent clones receiving the
  same queue are unsupported without a stronger distributed claim mechanism.
- Do not run another auto-commit process against the checkout.
- The optional receipt notifier is read-only: it reads
  `tasks/receipts/to-local/`, writes only a seen list and a log outside the
  checkout, and passes receipt text to the notification binary with quotes and
  backslashes escaped. It starts no agent and costs no model usage. A receipt is
  a hint: it cannot authorize work, and its text must not be copied into shell
  commands.
- The webhook template retries delivery. Remote execution is not exactly-once;
  tasks with external side effects need their own idempotency and recovery checks.
- Review artifacts before adding them to the task repository. Large or sensitive
  outputs may require another explicitly approved delivery channel.

Report a suspected security issue privately to the repository maintainer through
an available private contact/security-reporting channel, not a public issue
containing credentials. Rotate exposed credentials immediately.
