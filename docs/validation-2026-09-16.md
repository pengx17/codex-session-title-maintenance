# Task-state redesign validation

## Automated contracts

58 tests / 219 assertions passed with macOS system Ruby. Coverage includes exact citations, cross-batch requirement retention, user-only topic replacement and waiver, pending acceptance after merge, ongoing monitoring, partial/large transcript records, model failure without cursor advancement, corrupt-checkpoint isolation, lifecycle ordering, new messages during model/write, provisional writes without premature ACK, manual-name concurrency, app-server and index readback, and legacy automation exclusion.

Independent review reproduced and closed PR repository mismatch, lifecycle timestamp ordering, premature provisional ACK, monitoring completion and corrupt-checkpoint global blockage. Queue retries rotate by eligibility time before original revision.

## Real semantic replay

Used the actual configured Terra/high model and complete meaningful message streams, with isolated shadow checkpoints. Private transcripts and task IDs remain local.

| Case | Batches | Source consumed | Result |
| --- | ---: | ---: | --- |
| iMessage origin, later sustained WeChat work | 8 | 96,866,608 bytes | Replaced the goal with WeChat in batch 4; retained it through batch 8. Outstanding acceptance remained open. |
| Telegram latency, merged but not accepted | 3 | 49,529,095 bytes | Recognized subsequent work and its newer PR as well; outstanding deployment and acceptance prevented completion. |
| Telegram cards/replies, actually accepted | 1 | 11,604,508 bytes | Implementation, merge, deployment, acceptance and overall outcome all satisfied; rendered completed. |

Some initial model proposals failed literal-evidence or repository validation. Those failures did not advance state. The final extraction schema restricts message IDs and repositories to observed inputs; repair receives the rejected proposal and the exact validation error. All three final replays consumed the full source boundary available to that pass.

These are regression examples, not a statistical claim that semantic extraction is infallible. New user work can arrive after replay; the installed worker consumes it incrementally.

## Installation

Kept a local rollback copy of the previous runtime, preserved the durable event queue, and imported the three validated checkpoints without reinterpreting legacy title timestamps. The installer completed with trusted lifecycle hooks, loaded LaunchAgent and a real Stop-to-queue canary. The installed worker successfully wrote the WeChat title and verified it through app-server and index readback.

Other recent/pinned tasks reconstruct in the background. Infrastructure readiness, source reconstruction and applied title evidence are reported separately. No claim is made that a successful canary means every historical task has already been rebuilt.
