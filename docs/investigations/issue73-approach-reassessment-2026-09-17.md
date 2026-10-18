# Issue 73 approach reassessment

> Investigation report, observed 2026-09-17 on `bugfix/73-queued-start-steering` against `main` at `37f16fbd`. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/spec/headless-mcp-domain-runtime-m5-ai-agent-interaction.md](../spec/headless-mcp-domain-runtime-m5-ai-agent-interaction.md), Authority and compatibility ledger.

## Run abandoned

MP abandoned this implementation run. Issue 73 remains unresolved. Preserve the candidate as investigation material; no replacement design is approved and no repairs or reviews are scheduled. The conclusions below record the source assessment at the time of abandonment.

## Confirmed current scope

The candidate is isolated on bugfix/73-queued-start-steering at distribution main 37f16fbd. Nine tracked files differ: 6,769 added lines and 191 deleted lines; most additions are tests (5,362 in the admission suite). Seven production files change. Repeated failures have concerned operation ownership across asynchronous startup, epoch changes, cancellation, routing and initial responses. The thirteenth review of the candidate identifies an initial-response stale-terminal race still unresolved. Passing tests do not establish packaged-runtime acceptance; debug smoke remains deferred while MP works.

## Original issue and upstream comparison

Two bounded read-only scouts completed. The findings cover source and history; runtime validation is pending.

Original distribution issue 73 requires that steering while agent_run start is Queued to start must not cancel the target. Delivery in order or an explicit retryable rejection satisfies the stated requirement, with a race-focused Claude startup regression.

Upstream reference examined: ea2d2bb02516f4c6f4192efb97926deaf184d713. The scout found the same pre-run Task handoff gap: executeSteer branches on runState.isActive; inactive steering sets mcpFollowUpRunPending and dispatches with allowStartingRun. Upstream has no MCPRunStartupClaim or equivalent queue acceptance for this gap. Claude's provider-start boundary starts after its runner is entered. AgentRunStartOutcomeRecorder serves cross-session delivery receipts, not this queued-start steer path. Distribution main 37f16fbd has the same boolean startup mask and asynchronous handoff, but lacks newer upstream outcome-recorder plumbing and activation guards. Upstream freshness and exact code references should be confirmed by the design assessor before recommending reuse.

Relevant upstream sources: commit 9fe26ab8 handles startup-pending cancellation, upstream PR 96/commit4b61e0d9 introduced stable registrations/epochs, upstream PR 353/commit11549d20 reactivates inactive steering. None was established as a queued-start steering fix.

Similar filed reports and dispositions:

- Distribution issue 73 remains open: queued-start steering cancels the target; no linked PR.
- Distribution issue 12 and PR 51 fixed a delivered steer returning Expired by following its accepted epoch. Same wait identity class, different startup trigger.
- Upstream PR 190 superseded PR 151 for expired steering waits; PR 152 fixed Codex ACK/cancellation races.
- Upstream issue 384 and PR 669 carry steering text through waiter notifications with duplicate suppression and identity revalidation.
- Upstream issue 867 remains open: stopping ACP can lose queued steering behind an active tool. Adjacent provider/timing case.
- Upstream PRs 742, 763, 764, 772 and 778 establish admission, durable lifecycle, transient attempts and terminal ownership boundaries. These provide architectural precedents for the design review.
- Upstream issue 882 and PR 897 address serialized same-workspace admission and exactly-once dispatch.
- Upstream issue 133 remains open, proposing explicit lifecycle states and monotonic cursors.

Search scope covered open/closed records in both repositories and linked dispositions, using paginated records after GitHub search rate limiting. The search found no exact upstream match within that scope; live validation is pending.


## Design reassessment

Recommendation: simplify. Keep an exact-owner startup claim that makes a second inactive steer fail with an explicit retryable status while startup is pending. Keep the domain session store authoritative for run identity and completion.

The baseline service prepares the run epoch before obtaining the initial response snapshot (AgentRunMCPToolService.swift at distribution HEAD, lines 1049–1050). The candidate removes that call and introduces acceptance-cursor tracking to reconcile waits that begin before admission. The independent design critique identifies this additional tracking as the source of much of the repair churn. Restore service-side preparation with exact-owner claim fencing; retain the existing start-task preparation fallback. The baseline helper returns when preparedEpoch already exists (AgentModeViewModel.swift, lines 5853–5858).

A bare pending boolean is insufficient: baseline mcpSnapshot can clear it after 15 seconds when the provider task has not started (AgentModeViewModel.swift, lines 6033–6047). Exact operation ownership must survive that window and must prevent stale callbacks from clearing a newer startup claim.

The parent independently checked the removed service call, the prepared-epoch early return, the 15-second mask expiry, and DomainAgentRunSessionStore.snapshot/currentCursor using record.currentEpoch. The M5 authority ledger assigns session lifecycle to the domain store; the view model projects state. These checks support simplification but do not prove that a reduced implementation is correct.

The proposed reduced scope removes the extra accepted-cursor state, startup-specific wait ownership, epoch-preparation reservations and own-wake attribution used only by that wait layer. Each removal must be justified against actual remaining consumers during implementation. Route-binding and UI-start interactions require focused review; the critique's suggested removals are not independently validated implementation instructions.

The critic confirmed upstream reference ea2d2bb0 matches remote main and found the relevant lifecycle/attempt ownership precedents already in distribution HEAD. No direct upstream fix was identified. The original cancellation mechanism remains plausible from source inspection, not reproduced in the packaged app.

## Proposed validation of the reduced implementation

1. Hold a real starter before provider launch, age the pending timestamp beyond 15 seconds, poll and send a steer. Require a retryable rejection, unchanged startup owner and one eventual provider attempt.
2. Steer a completed session with wait enabled while holding the new start. Require the wait to return the new run's canonical completion, never the retained previous completion.
3. Exercise cancellation, startup failure/retry, a late callback from the old owner, and a UI start during deferred MCP startup. Require exact-owner cleanup and no duplicate attempt.
4. When MP resumes the validation window, run repeated packaged-debug start/steer trials with distinct messages. Record ordered delivery or rejection followed by successful retry, and verify no induced cancellation. If the queued-start window is not observed, report that limitation.

## Maintainer-guidance check

User impact: a steer during queued startup must preserve the target run. Root-cause confidence: competing-start admission is supported by source; the reported cancellation outcome still needs runtime reproduction. Authority: DomainAgentRunSessionStore owns epochs and completion. State risk: stale callbacks, cancellation and reactivation must not settle another operation. Scale: the reduced scope should add no polling loop or background process. Recommended scope: simplify the startup fence and preserve existing wait behavior. Validation boundary: source reassessment is complete; implementation and packaged-debug acceptance remain pending.

## Disposition

This run is abandoned. The fourteenth review was not consumed. Packaged-debug validation was not completed. Future work requires a new decision and independent assessment of the original report.

## Decision criteria

- Required user-visible behavior and smallest coherent change.
- Existing owner of startup, accepted turn identity and wait continuity; whether new local state creates a competing authority.
- Upstream mechanism and relevant distribution drift, with concrete revision references.
- Keep, simplify or replace recommendation with migration risk and bounded verification.

## Verification boundary

No source edits, app launches, runtime smoke, merges or releases are part of this assessment. Preserve production and all worktree edits.
