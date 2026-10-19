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

Not yet verified for this extracted public version:
- Fresh real launchd installation over a full scheduling cycle.
- Real GitHub Actions secret delivery and cloud webhook reception.
- Fresh Grok routine creation, payload presentation and skill auto-discovery.
- Cloud accepted/result pushes from the new dedicated checkout.
- End-to-end two-direction execution using the public English metadata format.

The earlier private deployment passed bidirectional execution and real macOS
timer delivery. It used localized metadata and a different cloud sync model.
Those results do not replace the above fresh-install checks.
