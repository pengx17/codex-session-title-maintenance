---
name: codex-session-title-maintenance
description: Maintain accurate, searchable Codex task titles from recent work, status emoji, PR lifecycle, and persisted timestamps. Use when reviewing, batch-renaming, or scheduling silent maintenance of Codex session titles.
---

# Codex Session Title Maintenance

Apply only to Codex tasks, never ChatGPT conversations.

## Event-driven path

The installed flow is:

```text
SessionStart/UserPromptSubmit/Stop hooks -> durable queue -> launchd worker -> verified Codex title write
```

- `title_event_hook.rb` captures task start, new user goals, and completed turns without blocking or failing the Codex session.
- Codex owns the initial task title. A user prompt starts a fast provisional pass after 20 seconds so long-running tasks do not keep a stale title; non-PR provisional titles remain `🔄`. A Stop event schedules a final pass after 90 seconds so completed context and status can correct the title.
- `title_event_worker.rb --daemon` is always on and batches semantic decisions. Events are processed regardless of weekday or clock time.
- Explicit lifecycle/PR events bypass the stale `session_index.jsonl` timestamp filter after their debounce. Before deciding, read the live Codex title/version; immediately before writing, read it again. A provisional active-task decision may tolerate timestamp-only progress, but any title change still discards the stale decision. Final decisions also require the task status and version to remain unchanged.
- Poll only already-tracked open PR metadata every ten minutes. PR status-class changes are deterministic and do not invoke a model. Use `gpt-5.6-terra` at `high` only for semantic title decisions.
- Keep executables separate: use the configured CLI for Terra decisions, and the Desktop-bundled Codex binary for the short-lived writable app-server. Do not substitute an older standalone stdio app-server.
- On worker startup, reconcile recent and pinned threads as a loss-recovery warmup, with a 30-minute persisted cooldown to prevent crash-loop model churn. Also reconcile once per Beijing calendar day while the daemon remains alive; neither path is an hourly model scan.
- A transient failure waits ten minutes. Notify through macOS only after the second consecutive failure; never create a Codex inbox item.

Core scripts:

```text
scripts/title_event_hook.rb
scripts/title_event_worker.rb
scripts/title_maintenance.rb
scripts/title_event_install.rb
```

## Install, repair, or migrate

Always use the installer instead of hand-editing `hooks.json`, `config.toml`, or a LaunchAgent:

```bash
INSTALLER="${CODEX_HOME:-$HOME/.codex}/skills/codex-session-title-maintenance/scripts/title_event_install.rb"
/usr/bin/ruby --disable=gems "$INSTALLER" install --canary
/usr/bin/ruby --disable=gems "$INSTALLER" doctor
```

The installer is idempotent. It derives the current home and Codex directories, finds Apple Silicon or Intel Homebrew executables, preserves unrelated hooks, writes trust through Codex `config/batchWrite`, and safely reloads an always-on launchd worker. A successful install requires one enabled and trusted hook for each supported title event, a loaded valid LaunchAgent, a paused-or-absent legacy heartbeat, and a real Stop canary that verifies thread-id extraction and an isolated durable-queue write.

To migrate, first verify the target's identity; never infer it from the nearest SSH alias. For a LAN Mac, resolve its Bonjour SSH service and confirm hostname, user, architecture, GUI launchd domain, and Codex home before copying anything. Then copy this entire skill directory into the target Mac's `$CODEX_HOME/skills/` and run the same `install --canary` command from that Mac's logged-in GUI user. Preflight Codex/app-server, `gh`, filesystem paths, network reachability, and existing host authentication before requesting any new login. Never copy source-machine absolute paths or trusted hashes; the target installer regenerates both.

## Decide titles

Format: `<status emoji> [optional stable tag] concise Chinese topic`.

- `🔄` implementation or Draft
- `🟡` open non-Draft PR / CI / review / merge-ready
- `⚠️` confirmed blocker or failed gate
- `⏸️` waiting for a person, external system, or acceptance
- `✅` completed or merged
- `⛔` closed without merge
- `⏱️` scheduled monitoring

The status emoji must be first and the only decorative emoji. Preserve useful tags such as `[Project]` or `[Project PR #123]`. Rename only for a generic/inaccurate title, a missing key topic/tag, or a changed status. Idle does not mean complete.

If a candidate contains a PR number/URL or clearly concerns a PR, query live GitHub metadata first. The current PR state overrides historical context.

## Record safely

- Kept: `record` the candidate's `updated_at_ms` with `disposition=kept`.
- Renamed: use only Codex app-server `thread/name/set`; then `lookup --thread-id <id> --after-ms <old_ms> --timeout-ms 5000`, verify the exact title, and `record` the returned timestamp with `disposition=renamed`. Never place a generated title in a shell command.
- After every candidate is recorded, call `finish` with the returned `run_id`, current time, and `window_start_ms`.
- Do not archive, pin, delete, message, or otherwise mutate tasks.

For manual recovery, run `title_event_worker.rb --force-reconcile`; use `--dry-run` first when diagnosing candidate selection. `--allow-outside-hours` remains a compatibility no-op for older commands. The legacy `title_maintenance.rb run` path remains available for diagnosis only. Use `CODEX_TITLE_OWNER_ID` only when a deployment has a specific owner task to exclude; never bake a source-machine task ID into portable code. Never call `list_threads`, create a duplicate automation, or reactivate the retired hourly heartbeat.
