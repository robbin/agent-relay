# Contributor instructions

This repository distributes a public integration kit, not live tasks.

- Do not copy personal task histories, host-specific credentials, Bot IDs or user paths here.
- Keep runtime tasks in a separate private repository. Never enable the cloud notification template in this source repository.
- Public v1 uses English metadata, including the optional `- Executor:`, `- Role:` and `- Target directory:` fields. Protocol changes must update the skills, example, filter, docs and tests together.
- Keep the local sync timer pull-only. The optional runner may claim only pending tasks that explicitly opt in with a matching `- Executor:`; every other task keeps the explicit local takeover boundary.
- The runner must stay off by default, require an explicit install flag, support dry-run, and use the shared Git/task locks. Never test dispatch against a real executor without authorization.
- Test in disposable local repositories. Never install a real launchd job, send a real webhook or create cloud test tasks without explicit authorization.
- The cloud adapter uses a dedicated checkout and narrow claim/result commits, not an external whole-workspace auto-commit daemon. The local runner uses the same narrow-commit rule and only commits the task file.
- Keep docs/validation.md honest: mocked tests, including the runner's fake executor, are not live integration tests.
- Run bash tests/test-sync.sh, bash tests/test-notify.sh and bash tests/test-relay-runner.sh, bash tests/test-relay-guard.sh before proposing a release; on macOS also run bash tests/test-installer-macos.sh.
- Do not publish a repository, push externally or change a production installation without authorization for that step.
