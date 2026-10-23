# Validation record

Candidate validation on macOS, 2026-10-19. This is not a production-readiness claim.

Passed in disposable local Git repositories:
- Unchanged checkout and real fast-forward from a bare remote.
- Dirty worktree and staged changes are preserved.
- Existing Git lock is preserved and causes a skip.
- Wrong branch and unfinished cherry-pick marker cause a skip.
- Ahead/diverged histories are preserved.
- Origin mismatch and fetch failure return errors and release the owned Git lock.
- Notification filter handles whole-push additions, status-only changes,
  additions completed before push, local tasks, deletion and conservative
  forced/zero/missing-history wakeups.
- macOS installer produces valid plist with escaped paths, refuses duplicate
  install, and uninstall preserves repository/logs. launchctl was MOCKED:
  no real job was registered and no production sync service was touched.
- Workflow templates and both skill frontmatters parse as YAML. Shell syntax checks pass.
- GitHub Actions run [39219667010](https://github.com/robbin/agent-relay/actions/runs/39219667010)
  passed on ubuntu-latest and macos-latest. The installer test still mocks launchctl
  on macOS and skips on Linux; this does not constitute a live timer installation.

## Optional relay-runner candidate, 2026-10-23 (hardened runner)

Passed in disposable local Git repositories with a mocked executor; no macOS
job was registered and no real agent, model or webhook was used:
- `tests/test-relay-runner.sh` covers dry-run, claim with a narrow task-only
  commit and push, dispatch arguments and prompt (`--cwd`, provider/thinking,
  no `--no-wait`, prepare-only rule, no-push rule), the dispatch marker, the
  one-task-at-a-time gate, non-opted-in/blocked/accepted filtering, the dirty,
  sync-timing, behind-origin and expected-origin gates, the directory allowlist,
  executor failure, role/provider presets, the `command` adapter, the pause
  marker, a run lock the runner did not create, and a filename/ID mismatch.
- `tests/test-relay-guard.sh` covers guard 1 (`..`, symlink escape, projects
  root), guard 2 (body scan, non-ASCII wording, pre-filled Result, embedded
  Result heading, no false positive on "token count") and guard 3 (secret in
  Result/other file/commit message/binary/merge/deleted blob, executor's own
  push refused, `RELAY_GUARD_WAIT=0` refused).
- `tests/test-relay-runner-fixes.sh` covers the failure path through the output
  gate, per-commit/per-blob scanning, 1 MiB and binary fail-closed handling with
  `RELAY_GUARD_BLOB_ALLOW`, shared-lock and exact-path commits, task ID
  validation, blocked receipts, and executor arguments.
- `tests/test-relay-runner-regressions.sh` covers merge-only blobs, receipts
  that disagree with the task (reverse, missing, removed requirement, wrong
  identity), lock re-validation (branch switch, status change), HEAD moving
  after the scan, grep/git error injection failing closed, odd file names, and
  the pause/lock race.
- `tests/test-relay-runner-safety.sh` covers cross-process execution evidence
  (`approved-head`, retry after a network failure, quarantined `hold/`), a
  single-process cleanup failure, injected `mkdir`/`rmdir` errors, uncommitted
  executor output, divergence, `write_pause` failure modes (directory, dangling
  symlink, missing parent, concurrent creation), run-lock variants that are
  never reclaimed, the refusal of asynchronous dispatch, and 14 probes where the
  executor drags another control file into its commit (other task, deletion,
  rename, reverse receipt, to-cloud change, protocol edit, receipt removal) —
  each refuses the whole push and keeps the evidence.
- `bash -n` passes for every shipped script and test.

Not verified for this candidate: a real Paseo dispatch, a live role preset file,
a real launchd schedule, an end-to-end agent that writes Result and commits, and
cross-process contention with the real sync timer beyond the mocked cases. These
are mocked tests, not a live integration test.

## Optional relay-runner candidate, 2026-10-22

Passed in disposable local Git repositories on Linux (mocked executor, no macOS
job registered, no real agent started):
- `tests/test-relay-runner.sh` covers dry-run (no file/Git change, no dispatch,
  no task lock), claim with a narrow task-only commit and push, English
  `- Status: accepted` / `- Updated:` rewrite, dispatch marker, retained task
  lock, and the one-task-at-a-time gate.
- Non-opted-in pending tasks, `blocked` and `accepted` tasks are never claimed.
- Dirty worktree, local commits ahead of origin/main, unfinished Git state and
  missing origin/main cause a skip and preserve the scene.
- Sync timing gate skips both a too-recent and a too-stale sync log.
- Target directory handling: allowed in-allowlist path passed as `--cwd`,
  outside-allowlist and missing paths both become `blocked` without dispatch.
- Executor start failure becomes `blocked` and releases the task lock.
- Unknown role and unavailable provider become `blocked`; no role/provider is
  substituted. A valid role preset passes provider/model/mode/thinking and its
  notes; unapplied `featureValues` are logged.
- The configurable `command` adapter receives task ID, cwd/role flags and the
  prompt on stdin. Pause marker, stale run-lock reclamation, live run-lock
  respect and filename/ID mismatch handling are covered.
- `bash tests/test-sync.sh`, `bash tests/test-notify.sh` and
  `bash tests/test-relay-runner.sh` pass locally. Shell syntax checks pass for
  all shipped scripts.
- `tests/test-installer-macos.sh` was extended for optional runner plist
  generation, escaped paths, reserved env rejection, duplicate refusal, and
  uninstall preserving repo, logs, runner state and task locks. It skips on
  Linux, so it was NOT executed for this record; macOS CI must run it with
  launchctl still mocked.

Not verified for this candidate:
- A real Paseo dispatch, real role preset lookup against a live Paseo config, or
  real `paseo provider ls` output.
- A real launchd installation/scheduling cycle for `io.agent-relay.runner`.
- End-to-end automatic local execution where a real agent writes Result, commits,
  pushes and releases its own task lock.
- Automatic bidirectional relay through a fresh Grok account, including a cloud
  sender adding `- Executor:` and a real local runner claim.
- Cross-process contention between the real sync timer, the runner and a manual
  takeover beyond the mocked lock/timing cases.

The runner tests are mocked unit/integration tests, not a live integration test.
The earlier private deployment passed bidirectional execution and real macOS
timer delivery. It used localized metadata and a different runner implementation.
Those results do not replace the above fresh-install checks.

## Round-trip receipts candidate

Added in this candidate: the optional `- Receipt: required` header, the
`tasks/receipts/to-cloud|to-local/` directories, the two webhook events
(`tasks-to-cloud-pending`, `tasks-to-cloud-receipt`), and the optional read-only
receipt notifier.

Passed offline, in disposable local Git repositories and temporary state
directories:
- `tests/test-notify.sh` now also covers the receipt event: a new
  `tasks/receipts/to-cloud/<ID>.md` notifies, while README edits,
  `tasks/receipts/to-local/` changes and the pending-task event do not; forced,
  zero and missing-history pushes stay conservative; `--ids` lists candidate IDs;
  an unknown event name fails.
- `tests/test-receipt-notify.sh` covers the notifier with a faked notification
  binary: the first run only records existing receipts as seen, a new receipt is
  notified once with its result status and summary, repeated runs deduplicate,
  a failed notification is logged and retried on the next run instead of being
  marked seen, `tasks/receipts/to-cloud/` and README files are ignored, the
  checkout is unchanged after a run, a missing receipt directory is a harmless
  skip, and a relative checkout path is rejected.
- `tests/test-installer-macos.sh` now also generates and lints the
  `io.agent-relay.receipt-notify` plist, checks ProgramArguments, interval,
  RunAtLoad and state/log paths, refuses a duplicate install, installs all three
  jobs together and removes all of them on uninstall. launchctl is MOCKED; on
  Linux the test skips.
- Shell syntax checks (`bash -n`) pass for every shipped script and test.

Not verified:
- The real Actions workflow, real webhook delivery and a real cloud agent
  continuing from a receipt event.
- A real macOS notification, a real launchd schedule for the receipt notifier,
  and Notification Center behavior when notifications are muted.
- A real sync-plus-notify cycle where the pull-only timer delivers a receipt and
  the notifier fires in the same session.

These receipt checks are offline tests with fakes; they are not a live
integration test of the two-endpoint round trip.
