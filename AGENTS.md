# Contributor instructions

This repository distributes a public integration kit, not live tasks.

- Do not copy personal task histories, host-specific credentials, Bot IDs or user paths here.
- Keep runtime tasks in a separate private repository. Never enable the cloud notification template in this source repository.
- Public v1 uses English metadata. Protocol changes must update the skills, example, filter and tests together.
- Preserve the pull-only local timer and explicit local takeover boundary.
- Test in disposable local repositories. Never install a real launchd job, send a real webhook or create cloud test tasks without explicit authorization.
- The cloud adapter uses a dedicated checkout and narrow claim/result commits, not an external whole-workspace auto-commit daemon.
- Keep docs/validation.md honest: mocked tests are not live integration tests.
- Run bash tests/test-sync.sh, bash tests/test-notify.sh and (on macOS) bash tests/test-installer-macos.sh before proposing a release.
- Do not publish a repository, push externally or change a production installation without authorization for that step.
