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
  2. Task body scan, before the task is claimed: everything except the
     metadata headers the runner validates itself (`Task ID`, `Status`,
     `Executor`, `Role`, `Target directory`) is matched — including any
     pre-filled `## Result` text, since a pending task's Result should be empty — against sensitive patterns: `.ssh`, `id_rsa`,
     private keys, `.env`, Keychain, `auth.json`, secrets/credentials/passwords,
     narrow token forms (access/auth/api/refresh/bearer/bot token, `token=`),
     `.aws`, `.gnupg`, cookies, `scp`/`rsync host:`, `curl`/`wget` uploads,
     `nc`, paste sites. The executor is not started.
  3. Output gate (`RELAY_GUARD_WAIT=1`, default): the executor commits but does
     not push; its own pushes are disabled on a best-effort basis by an
     invalid `remote.origin.pushurl` (set in the checkout config while the
     executor runs, unless you configured a pushurl yourself, and injected
     through `GIT_CONFIG_*` env), removed again afterwards. The
     runner scans exactly what would be pushed — every commit in
     `origin/main..HEAD`: commit messages and all added lines, binary content
     included, merge resolutions, and blobs deleted again by a later commit — for likely secrets
     (GitHub/OpenAI/Slack/AWS tokens, private key blocks, long hex/base64
     strings, Bearer values, `*KEY/TOKEN/SECRET = ...`). Clean output is
     pushed by the runner (that exact scanned commit) under the shared Git
     lock; a hit is recorded as `blocked` in a local-only commit, `PAUSED` is
     written and nothing is pushed. Uncommitted leftovers are never pushed.
     `RELAY_GUARD_WAIT=0` disables this gate.
  Pattern scans are a safety net, not a guarantee: they can miss obfuscated or
  unusual secrets, an executor with its own credentials or a cleared
  environment can still push directly, and legitimate tasks that mention
  sensitive words get blocked.
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
  future dispatches but cannot stop an executor that is already running.
- Locks are cooperative and local to a checkout, not distributed leases.
  Use one receiving checkout per role. Multiple independent clones receiving the
  same queue are unsupported without a stronger distributed claim mechanism.
- Do not run another auto-commit process against the checkout.
- The webhook template retries delivery. Remote execution is not exactly-once;
  tasks with external side effects need their own idempotency and recovery checks.
- Review artifacts before adding them to the task repository. Large or sensitive
  outputs may require another explicitly approved delivery channel.

Report a suspected security issue privately to the repository maintainer through
an available private contact/security-reporting channel, not a public issue
containing credentials. Rotate exposed credentials immediately.
