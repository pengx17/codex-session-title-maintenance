# Codex Session Title Maintenance

Event-driven Codex task-title maintenance for macOS. It uses trusted Codex lifecycle hooks, a durable local queue, an always-on per-user `launchd` worker, live PR metadata, and incremental evidence-backed task state to keep task titles accurate and searchable.

## What this is

This repository is an installable Codex Skill with a small local runtime:

- `SKILL.md` defines when Codex should use it and the title/status policy.
- `scripts/` implements event capture, durable processing, model decisions, PR-state tracking, installation, and diagnostics.
- A per-user LaunchAgent runs the worker in the background on macOS.

It is not a Codex plugin or an hourly scheduled task. The primary path is event-driven and runs regardless of weekday or time of day. Startup and once-per-Beijing-day reconciliation recover missed events and include pinned tasks.

```text
SessionStart/UserPromptSubmit/Stop hooks -> durable queue
  -> ordered transcript batches -> cited durable task state
  -> live PR facts -> deterministic title -> verified Codex title write
```

## Native-title compatibility

Codex still owns the initial title. This tool is a delayed second pass:

1. Codex creates its native task title.
2. `SessionStart` and `UserPromptSubmit` hooks capture new or resumed goals without blocking the task.
3. After 20 seconds, a provisional pass becomes eligible; active tasks display `🔄`. Initial reconstruction and model latency add processing time.
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

- always-on lifecycle-event processing with no working-hours restriction
- 20-second provisional title pass after a new user goal
- 90-second final title pass after Stop
- startup reconciliation of recent and pinned tasks, protected by a 30-minute persisted cooldown
- one recovery reconciliation of recent and pinned tasks per Beijing calendar day
- ten-minute PR metadata polling for current goal associations; merged PRs retain outstanding acceptance
- status prefix: `🔄` `🟡` `⚠️` `⏸️` `✅` `⛔` `⏱️`
- transient failures retry after ten minutes; a macOS notification is sent only after the second consecutive failure

Optional environment variables include `CODEX_TITLE_MODEL`, `CODEX_TITLE_REASONING_EFFORT`, `CODEX_TITLE_OWNER_ID`, and the executable overrides documented in the scripts. Copy `config/pinned-thread-ids.txt.example` to `config/pinned-thread-ids.txt`, then add one task ID per line; the published example intentionally contains no real task IDs.

## Tests

```bash
ruby -Itests -e 'Dir["tests/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
```

The tests cover transcript segmentation/partial lines, evidence validation, requirement persistence, PR identity, completion and monitoring, atomic cursor recovery, lifecycle ordering, corrupt-checkpoint isolation, concurrent events, manual title changes and both title readbacks.

## Durable task state

See [ADR 0001](docs/adr/0001-evidence-backed-task-state.md) for the contract and limitations.

The model proposes cited state changes, not titles. Each requirement survives until resolved, explicitly waived by the user, or archived with a user-evidenced goal replacement. The renderer checks every requirement and live current PR facts; merge alone never establishes acceptance. Initial reconstruction must finish before publishing a title. Subsequent passes consume only new messages.

Checkpoints live under `~/.codex/title-maintenance/tasks-v1/`. State and source cursor commit together. Per-task retries do not block other tasks. The queue retains unconsumed input even after a provisional title write. Legacy title timestamps are never reused as transcript cursors.

`doctor` distinguishes infrastructure readiness from semantic processing: queue age, reconstruction count and task errors. It does not equate an alive daemon with correct titles.

### Shadow replay

```bash
ruby scripts/title_task_replay.rb --thread TASK_UUID --root /absolute/shadow-directory --batches 20
ruby scripts/title_task_replay.rb --thread TASK_UUID --root /absolute/shadow-directory --inspect
```

Replay makes model and GitHub read calls and writes only the selected shadow checkpoint directory. It never changes task titles. Resume unfinished replay with the same root; choose a fresh directory for independent validation. Keep private transcripts and task IDs out of commits.

Before upgrading, keep a rollback copy of installed scripts and preserve queue/checkpoint data. Install using `install --canary`; verify representative title readbacks separately. The app-server has no atomic name compare-and-set, so the worker guards and requeues concurrent changes but cannot eliminate the final read/write race. Model extraction remains fallible; citations and replay make it auditable.
