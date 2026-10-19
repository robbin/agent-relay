# Architecture and acceptance

The source repository distributes code and documentation. A separate private
task repository carries live tasks. Both endpoints read its tasks/README.md.

The local timer only fetches and fast-forwards. A human starts the local session.
The cloud webhook wakes an already configured agent routine; it is not an agent
runtime and does not execute Markdown by itself.

Public v1 uses a dedicated cloud checkout and agent-owned narrow commits for
claims/results. It does not ship or require the original private deployment's
whole-workspace auto-commit daemon. This is a deliberate deployment difference.

## Harmless end-to-end acceptance

Use a disposable private task repository and explicit user authorization.

1. Local sends one complete pending to-cloud task requesting a fixed phrase in
   Result, allowing edits only to that task. Verify automatic cloud receipt,
   accepted claim, done result and remote commit.
2. Confirm the result-only push did not send another webhook.
3. Cloud sends one equally constrained to-local task. Leave the Mac timer alone;
   observe OK updated. Before takeover, the task must remain pending.
4. Ask the local agent to view only; verify no state change.
5. Explicitly take over; verify accepted was pushed before execution and done
   afterward. Check result on the remote.
6. Never claim timer delivery if a manual fetch/pull produced the update.

Record commits, timestamps and which actions were manual. Do not reuse IDs.
A file existing is not proof of skill discovery; test natural-language routing
separately. Do not generate more test tasks without authorization.
