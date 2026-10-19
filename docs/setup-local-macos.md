# macOS setup

Requirements: an active macOS user session, Git, a private task repository on
GitHub with main branch, and noninteractive fetch authentication through SSH or
the system credential manager. Configure Git identity for agent-created commits.

1. Clone the **task repository**, not this source repository, to a dedicated path.
   Initialize tasks/README.md and the two task directories as described in README.
2. From this source checkout, test a single pull:
   ```sh
   bash scripts/macos/sync.sh /absolute/path/to/tasks git@github.com:OWNER/TASKS.git
   ```
   The second argument must exactly match `git remote get-url origin`.
   It is an identity check, not a credential. Never embed tokens in URLs.
3. Install the timer:
   ```sh
   bash scripts/macos/install.sh /absolute/path/to/tasks
   ```
   Installation starts a pull immediately, then every 300 seconds. It does not
   start an agent or push. The installer refuses to overwrite an existing install.
4. Copy skills/local/agent-relay into your host's user skill directory.
   Tell the agent its role is local, the absolute task checkout path, expected
   repository identity and branch main. Host skill discovery is host-specific;
   explicit reading of SKILL.md is a valid fallback.
5. Ask to view incoming tasks, then explicitly take over a chosen task.

Installed files:
- ~/Library/LaunchAgents/io.agent-relay.sync.plist
- ~/Library/Application Support/agent-relay/sync.sh
- ~/Library/Logs/agent-relay/sync.log and sync-error.log

Check:
```sh
launchctl print gui/$(id -u)/io.agent-relay.sync
tail -n 30 "$HOME/Library/Logs/agent-relay/sync.log"
```

OK updated means a fast-forward happened, not execution. OK unchanged is normal.
SKIP means the branch, worktree, index, lock or outgoing commits need attention.
ERROR is also written to sync.log; an empty stderr log does not prove success.
Fetch has connection/low-speed limits, not a hard deadline for the whole process.

Uninstall with `bash scripts/macos/uninstall.sh`. It removes this timer and its
installed script, not the task checkout or logs. Do not install this candidate
alongside another process managing the same checkout. To update, uninstall then
install; review new source before replacing the installed copy.

The installer supports one task checkout per user. Multiple checkout scheduling,
other OS service managers and automatic local execution are out of scope.
