# ADR 0001: Derive titles from durable task state

## Problem

A title generated from the first few and last few messages forgets explicit goal changes and unresolved delivery requirements. PR merge and an idle app-server are not evidence of task completion. Regex corrections and larger context windows only postpone the same failures.

## Decision

Use one pipeline: ordered transcript messages -> cited task-state changes -> durable checkpoint -> live PR facts -> deterministic title. The model extracts facts and transitions; it does not choose emoji or rewrite the title independently.

- Read every user/assistant message incrementally, in bounded batches. Split long messages instead of truncating them. Skip tool output, reasoning, and injected environment/skill blocks. Do not skip intervening user requests.
- Store the current goal, prior goals, explicit requirements, requirement resolutions, PR associations and progress, each with exact message citations. Requirements survive indefinitely until satisfied, user-waived or archived by an evidenced goal replacement.
- A topic starts or changes only with new user evidence. Ordinary progress does not replace it. The `outcome` requirement represents the complete user goal; additional delivery/acceptance requirements are separate.
- Validate cited IDs and literal excerpts against the input batch. Invalid proposals leave both state and cursor unchanged. State and cursor are committed atomically; a crash may repeat a title write, never skip input.
- Render completion only when outcome and every requirement are satisfied, current PR facts are available and no current PR is open/closed-unmerged, and the source is caught up. A merge can discharge a merge requirement only; it cannot discharge deployment or acceptance.
- Keep provider facts separate from transcript claims. A PR event refreshes facts and rerenders the same state without a new model inference. Failed lookups are unknown, never completion.
- Save partial reconstruction checkpoints but publish no title until the initial transcript has been fully consumed. Later new user input or a newer queue event prevents stale writes. Timestamp-only activity and an app-server's `notLoaded` status are not semantic invalidation.
- Persist an explanation for every applied/kept/deferred title and expose queue age, reconstruction progress and per-task failures. An alive daemon is only infrastructure health.

## Recovery and limitations

Per-task atomic JSON checkpoints and revision-checked queue ACKs provide at-least-once processing. The legacy title index timestamp is never a transcript cursor. A changed/truncated source fails closed and requires reconstruction. Per-task errors must not stop unrelated tasks.

The app-server API has separate read and name-set calls, without compare-and-set. Check title and event/source versions immediately before writing, read back afterward, and requeue a concurrent change. This minimizes but cannot eliminate the last read/write race. Semantic extraction remains a model judgment; exact citations, replay evaluation and unknown states make mistakes inspectable rather than hiding them.

## Delivery checklist

- [x] Implement transcript checkpoints and cited task-state reducer.
- [x] Replace model-selected emoji, PR shortcuts and completion regexes.
- [x] Test source append/partial lines, restarts, new events, manual names, PRs and goal replacement.
- [x] Replay the WeChat topic shift and merged-but-unaccepted examples; retain a correctly accepted control.
- [x] Install with rollback copy, verify end-to-end title readback and observable processing health.
Delivery evidence is recorded in [the validation report](../validation-2026-09-16.md); source delivery is tracked in Git history.
