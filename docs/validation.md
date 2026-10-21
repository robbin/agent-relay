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
