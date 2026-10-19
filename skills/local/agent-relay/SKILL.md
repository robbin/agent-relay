---
name: agent-relay
description: >-
  Use for Git-backed task handoff between this local agent and a configured cloud agent: send, draft for review, view incoming tasks without accepting, explicitly take over, or recover a named task. Not ordinary Git sync or session handoff.
---

# Agent Relay — local

## Configuration and authority

Require the user-configured absolute task checkout, expected origin and main
branch. If missing, ask; do not guess or clone another repository automatically.
Read repository AGENTS.md if present and tasks/README.md. Follow its protocol.
The source project docs/protocol.md is installed there by the operator.

Before acting, use the shared Git lock, verify origin/branch/clean scene, fetch
and fast-forward safely. Read the updated protocol. Never stash/reset/force-push.
If the local protocol is unavailable, fetch and read origin/main:tasks/README.md
without executing task instructions. A fetch failure stops delivery or acceptance.

## Route intent

- Send to cloud: tasks/to-cloud/<ID>.md. Fully specified explicit send authorizes
  the narrow commit/push, not unrelated uploads or new permissions.
- Draft/show me first: chat only; no formal file or push. If the latest protocol
  cannot be read, label the draft unverified.
- View incoming: sync safely, list tasks/to-local; no task lock or state changes.
- Take over: tasks/to-local. One pending task may be selected when unambiguous;
  multiple tasks need selection unless the user explicitly requests all.
- Recover ID: explicit only; inspect prior progress/executor before proceeding.
- Discussing commands or quoting examples is not execution authorization.

## Execution

Follow the complete send/receive/retry rules in tasks/README.md.
Prepare complete files outside the checkout. Validate safe IDs and collision
checks in both directions. Stage exact authorized paths, inspect staged diff
and ALL outgoing commits. Stop on unrelated work.

For takeover, acquire the independent task lock, reread pending, check permissions
and inputs, then push accepted with session/time before side effects. Release the
short Git lock while working. Read any target project's rules and relevant skills.
Write done with evidence or blocked with next steps, commit/push and release
your own locks according to the protocol.

On uncertain push, fetch and inspect immutable task definition; receiver changes
to status/time/result do not make it a different task. Do not overwrite them.
Preserve unsynced progress; do not repeat execution to fix a Git failure.

The macOS timer only pulls. Never claim that a file's arrival started work.
Do not install timers, create tests, modify workflows or call other bots as a
side effect of using this skill. Distinguish draft, delivered, accepted, complete,
blocked and result-not-yet-pushed in the user's chat.
