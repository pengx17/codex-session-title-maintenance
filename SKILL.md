---
name: codex-session-title-maintenance
description: Maintain Codex task titles from durable goals, cited requirements, delivery evidence and live PR facts. Use when reviewing, batch-renaming, repairing or scheduling silent title maintenance.
---

# Codex Session Title Maintenance

Apply only to Codex tasks, never ChatGPT conversations.

## State before title

```text
lifecycle hooks -> durable queue -> ordered transcript deltas
  -> cited task state + atomic cursor -> live PR facts
  -> deterministic title -> verified app-server write -> exact-event ACK
```

- Consume every meaningful user/assistant message in order, across bounded batches. Split long messages; never use first/last message windows as the source of truth.
- Persist current goal, previous goals, outstanding requirements, resolutions, PR associations and progress. Omitted requirements remain open. Only evidenced user changes replace goals or waive requirements.
- Use `gpt-5.6-terra` at `high` to extract cited changes. It never chooses the title or emoji. Validate message IDs, literal excerpts, immutable requirements and PR identities. Rejected changes do not advance the cursor.
- Initial reconstruction publishes nothing until caught up. Legacy title timestamps are not transcript cursors. Per-task files under `~/.codex/title-maintenance/tasks-v1/` contain state, cursor, explanation and last applied title; `audit.jsonl` records transitions.
- Completion requires the outcome and every applicable requirement satisfied, no current open/unmerged PR, fresh PR facts, a fully consumed source and no active turn. Merge never satisfies deployment or acceptance. Ongoing monitoring is not complete.
- Poll current PR associations every ten minutes, including merged PRs whose task acceptance is still relevant. A PR poll rerenders stored state; unchanged transcripts require no model call. Failed provider reads are unknown.

## Events and safe writes

- Codex owns the initial native title. Hooks enqueue SessionStart, UserPromptSubmit and Stop without blocking or failing the task.
- UserPromptSubmit debounce is 20 seconds; active turns display `🔄`. Stop debounce is 90 seconds. These are eligibility delays, not processing-time guarantees; initial reconstruction and model latency add time.
- Persist lifecycle independently of queue ACK. Compare lifecycle timestamps with lifecycle timestamps, not PR-poll timestamps. `notLoaded` from a separate app-server is not proof of idle/completion.
- Worker runs continuously, with startup reconciliation (30-minute cooldown) and daily Beijing-calendar reconciliation of recent/pinned tasks. Process one bounded batch per task and rotate retries so long histories do not monopolize the queue.
- Before a title write, check the exact queue revision, current live title and new user input. Active provisional writes may tolerate assistant-only appends; ACK still requires all visible input consumed. Recheck after writing and retain concurrent events.
- Use only app-server `thread/name/set`. Verify exact name through both app-server and index lookup before recording success. Never edit Codex databases, rollouts or `session_index.jsonl` directly.
- Per-task failures retry after ten minutes without blocking other tasks. Repeated failures may notify through macOS, never a Codex inbox task. Corrupt files fail closed and remain available for diagnosis.
- The API has no atomic compare-and-set for names: final read/write races are detected/requeued, not claimed impossible. Semantic extraction still needs replay validation.

## Status policy

Format: `<status emoji> [optional stable project/PR tag] concise Chinese topic`.

- `🔄`: active turn, implementation, or draft PR
- `🟡`: current non-draft PR remains open
- `⚠️`: confirmed task blocker, failed gate, or current PR closed unmerged
- `⏸️`: unknown provider state or waiting for outstanding delivery/acceptance
- `✅`: all task requirements and outcome have completion evidence
- `⛔`: user cancelled the goal
- `⏱️`: ongoing monitoring

The current goal determines the topic. Implementation steps, PR review and merge do not independently rewrite it. Historical/reference PRs do not control current status.

## Install, repair and inspect

Always use the installer instead of editing hooks, config or LaunchAgent manually:

```bash
INSTALLER="${CODEX_HOME:-$HOME/.codex}/skills/codex-session-title-maintenance/scripts/title_event_install.rb"
/usr/bin/ruby --disable=gems "$INSTALLER" install --canary
/usr/bin/ruby --disable=gems "$INSTALLER" doctor
```

The installer preserves unrelated hooks, writes trust through Codex `config/batchWrite`, reloads launchd and runs an isolated Stop-to-queue canary. `infrastructure_ok` verifies installation; `processing` reports reconstruction, queue age and task errors. An alive daemon or a canary alone does not establish semantic title correctness.

Keep a rollback copy before replacing installed scripts. Preserve the live queue and task checkpoints. New installations reconstruct historical tasks; never convert legacy title timestamps into consumed-message cursors.

Read-only/shadow diagnostics:

```bash
ruby scripts/title_event_worker.rb --dry-run --force-reconcile
ruby scripts/title_task_replay.rb --thread TASK_UUID --root /absolute/shadow-directory --batches 20
ruby scripts/title_task_replay.rb --thread TASK_UUID --root /absolute/shadow-directory --inspect
```

Replay writes only its explicitly selected checkpoint directory, never task titles. Resume with the same root. Inspect shows goal/requirements/citations and pending work. Use a fresh shadow directory for independent semantic replay; do not silently reset production checkpoints. Changed/truncated source requires explicit reconstruction after preserving the old checkpoint.

Use the Desktop-bundled Codex executable by default for both model calls and short-lived writable app-server, with separate overrides. Older standalone CLI versions may reject current configuration. Keep launchd at Standard priority without LowPriorityIO; external-volume transcripts can otherwise stall.

For remote migration, verify hostname, user, architecture, GUI launchd domain and Codex home first. Copy the skill, preserve target-local pinned configuration, and run the installer as its GUI user. Never copy machine-specific trust hashes or absolute paths. Check actual executable, host authentication and network before requesting login.

Do not archive, pin, delete, message or otherwise mutate tasks. Do not call `list_threads`, create duplicate automations, or reactivate the retired hourly heartbeat. `CODEX_TITLE_OWNER_ID` is an optional deployment-local exclusion; never bake private task IDs into the repository. `--allow-outside-hours` remains a compatibility no-op. Legacy `title_maintenance.rb` context/record commands are diagnostic compatibility only, not the production decision path.
