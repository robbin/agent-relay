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
