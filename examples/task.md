# Harmless relay verification

- Task ID: 2026-01-01-relay-example
- Status: pending
- Updated: 2026-01-01T10:00:00+00:00
- Inputs: This file only.
- Task: Write RELAY-EXAMPLE-OK in Result.
- Constraints: Only update this file's status, timestamp and Result. No other files, external messages or bot calls.
- Acceptance: Result contains the exact phrase and truthful claim/completion times.
- Deliverable: Commit and push this task file.

<!--
This example is a to-cloud task: the local runner never touches to-cloud.
For a tasks/to-local task that should be dispatched automatically, a sender may
add the optional English header fields `- Executor: paseo`,
`- Role: optional-preset-name` and `- Target directory: /absolute/path`
(only with explicit user authorization). Omit all three to keep the manual
view/takeover flow. Keep them as real header lines, not inside a comment.

Add `- Receipt: required` (also a real header line, not part of this comment)
only for a round-trip task: the receiver then also writes a short receipt to
tasks/receipts/<opposite direction>/<ID>.md when it finishes. Omit it for a
one-way task.
-->

## Result
