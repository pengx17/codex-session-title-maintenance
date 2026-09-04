# Codex Session Title Maintenance

Event-driven Codex task-title maintenance for macOS. It uses trusted Codex lifecycle hooks, a durable local queue, an always-on per-user `launchd` worker, live PR metadata, and a bounded Codex model pass to keep task titles accurate and searchable.

## What this is

This repository is an installable Codex Skill with a small local runtime:

- `SKILL.md` defines when Codex should use it and the title/status policy.
- `scripts/` implements event capture, durable processing, model decisions, PR-state tracking, installation, and diagnostics.
- A per-user LaunchAgent runs the worker in the background on macOS.

It is not a Codex plugin or an hourly scheduled task. The primary path is event-driven and runs regardless of weekday or time of day. Startup and once-per-Beijing-day reconciliation recover missed events and include pinned tasks.

```text
SessionStart/UserPromptSubmit/Stop hooks -> durable queue
  -> provisional/final debounce -> launchd worker -> verified Codex title write
```

## Native-title compatibility

Codex still owns the initial title. This tool is a delayed second pass:

1. Codex creates its native task title.
2. `SessionStart` and `UserPromptSubmit` hooks capture new or resumed goals without blocking the task.
3. After 20 seconds, a conditional pass preserves the mainline topic and can reopen the status as `🔄` while the new turn is active, even after an earlier PR merged. An accurate title need not change.
4. A `Stop` hook schedules a final pass after a 90-second quiet window so complete context and status can correct the title.
5. The worker reads the live title and task version before deciding, then checks them again immediately before writing. A manual/native title change invalidates the stale decision.

The worker never edits Codex databases, rollouts, or `session_index.jsonl` directly. Title writes go through Codex app-server `thread/name/set` and are verified afterward.

## Requirements

- macOS with Codex Desktop and a working Codex CLI
- `/usr/bin/ruby`
- GitHub CLI (`gh`) authenticated when PR-aware titles are needed
- A model available to Codex; defaults are `gpt-5.6-terra` with `high` reasoning

### Why Ruby?

The runtime intentionally uses only the Ruby standard library so installation does not require a package manager, virtual environment, or downloaded dependencies on Macs that provide `/usr/bin/ruby`. LaunchAgents and hooks can invoke the same absolute executable in a minimal environment.

This is a deployment tradeoff, not a claim that Ruby is the best language for the domain. The scripts remain compatible with the older system Ruby used by supported installations. If the project grows into a broader cross-platform service, a managed Python runtime or a single compiled binary may become a better fit.

## Quick start

```bash
CODEX_ROOT="${CODEX_HOME:-$HOME/.codex}"
git clone https://github.com/pengx17/codex-session-title-maintenance.git \
  "$CODEX_ROOT/skills/codex-session-title-maintenance"
/usr/bin/ruby --disable=gems \
  "$CODEX_ROOT/skills/codex-session-title-maintenance/scripts/title_event_install.rb" \
  install --canary
```

The installer merges the `SessionStart`, `UserPromptSubmit`, and `Stop` hooks, records their trust through Codex, installs/restarts the per-user LaunchAgent, and runs an isolated end-to-end Stop-to-queue canary. The machine-specific `config/pinned-thread-ids.txt` is gitignored and is never published.

The command is idempotent, so it is also the repair path. It preserves unrelated Codex hooks and regenerates machine-specific paths and trust data locally.

Update an existing clone with:

```bash
CODEX_ROOT="${CODEX_HOME:-$HOME/.codex}"
git -C "$CODEX_ROOT/skills/codex-session-title-maintenance" pull --ff-only
/usr/bin/ruby --disable=gems \
  "$CODEX_ROOT/skills/codex-session-title-maintenance/scripts/title_event_install.rb" \
  install --canary
```

Verify later with:

```bash
INSTALLER="${CODEX_HOME:-$HOME/.codex}/skills/codex-session-title-maintenance/scripts/title_event_install.rb"
/usr/bin/ruby --disable=gems "$INSTALLER" doctor
```

## Behavior

Topic and status are separate: early user messages anchor the mainline, while recent messages describe progress. Follow-up questions, debugging steps, and individual deployments should not replace the overall topic. Explicit goal changes can. A completed status is reversible when work resumes; historical merged PRs do not freeze the whole conversation as done.

- always-on lifecycle-event processing with no working-hours restriction
- 20-second provisional title pass after a new user goal
- 90-second final title pass after Stop
- startup reconciliation of recent and pinned tasks, protected by a 30-minute persisted cooldown
- one recovery reconciliation of recent and pinned tasks per Beijing calendar day
- ten-minute PR metadata polling only for already-tracked active PRs
- status prefix: `🔄` `🟡` `⚠️` `⏸️` `✅` `⛔` `⏱️`
- transient failures retry after ten minutes; a macOS notification is sent only after the second consecutive failure

Optional environment variables include `CODEX_TITLE_MODEL`, `CODEX_TITLE_REASONING_EFFORT`, `CODEX_TITLE_OWNER_ID`, and the executable overrides documented in the scripts. Copy `config/pinned-thread-ids.txt.example` to `config/pinned-thread-ids.txt`, then add one task ID per line; the published example intentionally contains no real task IDs.

## Tests

```bash
ruby tests/title_event_test.rb
ruby tests/title_maintenance_test.rb
ruby tests/title_mainline_test.rb
```

The tests cover event-specific debounce/retry, lifecycle-hook capture, startup and Beijing-day reconciliation, active-task title updates, app-server transport, PR status mapping, stale-index recovery, and the native/manual-title concurrency guard.
