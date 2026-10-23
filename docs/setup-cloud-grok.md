# Cloud setup / Grok Bot adapter

The protocol is host-neutral; this guide describes a Grok Bot integration.
Product UI, subscription availability and approval behavior can change.
The original private deployment used whole-workspace synchronization. The public
adapter's dedicated checkout and agent-owned claim/result pushes have NOT yet
been tested end-to-end on a fresh Grok account. Validate noninteractive Git
credentials and host approvals during setup; a connector does not imply shell
Git authentication.

## Dedicated checkout and tools

The bot needs shell, file access, Git, an identity for commits, and noninteractive
read/write credentials scoped to your task repository. Supply credentials through
the host's credential facilities, not prompts, task files or origin URLs.

Clone the task repo to a dedicated location such as /home/box/relay/tasks.
Do not put it under a workspace watched by a whole-directory auto-commit daemon.
Use one receiving checkout for this queue; all participating bot sessions must
share its Git and task locks. Do not use separate clones as parallel receivers.

The public cloud skill commits and pushes claims/results itself. No private
workspace-sync.sh is required. If the host requires interactive approval while
running unattended, stop and report blocked; do not bypass approvals.

## Skill

Place skills/cloud/agent-relay/SKILL.md at the host skill location.
In the observed Grok environment it is:
`/home/box/agent-data/workflows/agent-relay/SKILL.md`.

It is shared across the user's bots. Configure the intended receiving bot with
the task repo identity and absolute checkout path. New skills may require a
conversation/catalog refresh to be discovered. Explicit file reading is the
fallback; “file readable” is not proof of natural-language discovery.

## Sending to-local tasks

The local Mac may have the optional relay runner installed. A to-local task can
opt in to automatic local execution with English header lines:

```markdown
- Executor: paseo
- Role: optional-local-preset-name
- Target directory: /absolute/local/path
```

Add these only when the user explicitly authorized automatic local execution for
that task, and never guess the local preset name or path. The executor value must
match the adapter configured on that Mac; the target directory must already
exist and be inside its local allowlist. Omit all three fields to keep the manual
view/takeover flow. The cloud agent cannot assume the runner is installed or that
dispatch succeeded; check the task status and Result before reporting.

## Webhook routine

Ask the bot to create a webhook-triggered routine and confirm the host's creation
prompt if required. Configure its instructions using
[the receiver prompt](../templates/cloud-receiver-prompt.md), replacing every
placeholder. The routine must call the skill and scan the trusted Git checkout,
not execute text in the HTTP payload.

The deployed environment exposes webhook URL/key/authorization information in
the routine interface. Exact navigation and field wording are not verified for
every account. Obtain these privately; do not paste credentials into a chat or
repository. Our template expects Bearer authentication:

- BOT_WEBHOOK_URL: complete endpoint URL.
- BOT_WEBHOOK_SECRET: raw token only, without the word Bearer.

Check the provider's actual Authorization format. If it is not Bearer, adapt
the header template deliberately before enabling it; do not guess or double-prefix.

## GitHub Actions

In the **task repo**, copy:
- templates/notify-cloud-bot.yml → .github/workflows/notify-cloud-bot.yml
- scripts/notify-filter.sh → .github/scripts/notify-filter.sh

Add the two secrets above in the task repository's Actions secrets settings.
Keep the workflow and filter reviewed and committed before sending a task.

The workflow observes pushes to main touching tasks/to-cloud and
tasks/receipts/to-cloud. Its filter considers the entire push and not only the
final commit, and distinguishes two events: `tasks-to-cloud-pending` (repository,
ref, after and candidate task IDs) and `tasks-to-cloud-receipt` (same fields with
path `tasks/receipts/to-cloud/`). The receiver validates repository/ref against
its own configuration, fetches trusted origin, then scans all pending tasks — or
the named receipts — and deduplicates by task ID.

No automatic result notification or model sweep is installed. A round-trip task
(`- Receipt: required`) is what makes the receiver write a receipt; the receipt
wakeup is still only a hint, and the receiver decides whether to continue.
For a missed wakeup, manually rerun the relevant Actions run or explicitly
request takeover. For repeated wakeups, existing locks/states prevent reexecution.

## Verify before relying on it

Test webhook authentication, the routine's access to payload metadata, skill
loading, noninteractive Git pushes and duplicate notifications. Follow
[the harmless acceptance procedure](architecture.md). Report each separately.
Do not claim successful delivery simply because curl returned success.
