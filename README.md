# Codex Session Title Maintenance

Event-driven Codex task-title maintenance for macOS. It uses a trusted Codex `Stop` hook, a durable local queue, an always-on per-user `launchd` worker, live PR metadata, and a bounded Codex model pass to keep task titles accurate and searchable.

## What this is

This repository is an installable Codex Skill with a small local runtime:

- `SKILL.md` defines when Codex should use it and the title/status policy.
- `scripts/` implements event capture, durable processing, model decisions, PR-state tracking, installation, and diagnostics.
- A per-user LaunchAgent runs the worker in the background on macOS.

It is not a Codex plugin or an hourly scheduled task. The primary path is event-driven and runs whenever a Codex task stops, regardless of weekday or time of day. A once-per-Beijing-day reconciliation exists only to recover missed events and include pinned tasks.

```text
Codex Stop hook -> durable queue -> five-minute debounce
                -> launchd worker -> verified Codex title write
```

## Native-title compatibility

Codex still owns the initial title. This tool is a delayed second pass:

1. Codex creates its native task title.
2. A `Stop` hook queues the task without blocking it.
3. The worker waits for five minutes of inactivity.
4. It reads the live title and task version, decides whether a correction is needed, then reads them again immediately before writing.
5. If the title, task version, or task status changed meanwhile, the stale decision is discarded and the task is requeued after another inactivity window.

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

The installer merges the Stop hook, records trust through Codex, installs/restarts the per-user LaunchAgent, and runs an isolated end-to-end Stop-to-queue canary. The machine-specific `config/pinned-thread-ids.txt` is gitignored and is never published.

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

- always-on Stop-event processing
- no working-hours restriction for queued Stop or PR events
- five-minute inactivity debounce
- one recovery reconciliation of recent and pinned tasks per Beijing calendar day
- ten-minute PR metadata polling only for already-tracked active PRs
- status prefix: `🔄` `🟡` `⚠️` `⏸️` `✅` `⛔` `⏱️`
- transient failures retry after ten minutes; a macOS notification is sent only after the second consecutive failure

Optional environment variables include `CODEX_TITLE_MODEL`, `CODEX_TITLE_REASONING_EFFORT`, `CODEX_TITLE_OWNER_ID`, and the executable overrides documented in the scripts. Copy `config/pinned-thread-ids.txt.example` to `config/pinned-thread-ids.txt`, then add one task ID per line; the published example intentionally contains no real task IDs.

## Tests

```bash
ruby tests/title_event_test.rb
ruby tests/title_maintenance_test.rb
```

The tests cover queue debounce/retry, Stop-hook capture, Beijing-day reconciliation, always-on event handling, app-server transport, PR status mapping, stale-index recovery, and the native/manual-title concurrency guard.
