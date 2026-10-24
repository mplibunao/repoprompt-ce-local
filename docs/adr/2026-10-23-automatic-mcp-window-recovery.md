# A capped MCP window recovers by itself

Status: accepted, 2026-10-23
Sources: #213, `docs/ledgers/2026-10-23-stability-fix-batch-2.md`

## Context

Structure-backed MCP tools (`read_file`, `get_file_tree`, `get_code_structure`, and the `prompt` changes) keep a per-window settlement lease after their deadline, until the work finishes. Upstream PR 822 capped each window at one released lease. Once a second call got stuck, every later file and code call in the window failed with a non-retryable error until the stuck calls finished or the app restarted. #213 records production windows in that state on 2026-10-15, 2026-10-19 and 2026-10-22. Agents run unattended across many windows, so a state that only a restart clears stops their work until someone notices.

Releasing a stuck call's lease isn't safe on its own. The call is still running, and when it finishes it can still add a file to the selection or commit a prompt change over newer state.

## Decision

- When a file or code call reaches a window at its cap, the settlement registry quarantines the window's escaped calls, the ones still holding a lease after their deadline passed or their request was cancelled, and runs the new call.
- Quarantine revokes, under the registry lock, whatever a call could still publish. A read's invocation fence stops its queued auto-selection at enqueue, in the selection worker, and at the selection write. A prompt change's commit arbiter refuses its commit. Closing a window or a connection revokes its calls the same way.
- A read's selection effect runs in its tab's side-effect lane and can keep running after the read returns. It keeps the read's lease until it finishes, so a stuck effect blocks and gets quarantined like a stuck call. Once the read is revoked and stops waiting, its effect no longer holds up later effects on the tab.
- Quarantined calls keep their leases and count against two limits until they finish: 2 outstanding recoveries per window, each quarantining the calls stuck at that moment, and 8 quarantined calls app-wide. A recovery quarantines all the window's escaped calls or none. Past either limit, the cap error returns and tells the agent to stop retrying and report the problem.
- The window's banner reports each recovery, and the unified log lists every quarantined call. Agents don't get a recovery tool.
- `apply_edits` doesn't take a settlement lease. Its own server-side limit and the commit arbiter bound it, and closing its connection revokes the arbiter.

## Alternatives considered

- Keep the restart-only state of upstream PR 822: windows that nobody watches stay stuck.
- A recovery button in the banner: the same, whenever nobody is watching.
- An agent-callable recovery tool: every client pays for its description on each `tools/list`, and agents told to call it would call it every time, which is automatic recovery with an extra round trip.
- Raise the cap, or expire leases after a time: a higher cap hides more retained work, and expiry gives up ownership while late work can still publish.

## Consequences

- A capped window works again on its next call without a restart. Once a recovered call's revocation wins, its late work can't overwrite newer selection or prompt state. A prompt change whose commit had already begun loses the revocation and may still apply. The recovery's log line and the DEBUG settlement snapshot record which calls lost.
- Stuck calls stay tracked. A recurring fault fills the limits and brings back the "stop and report" error instead of hiding behind repeated recoveries.
- The registry diverges from upstream's. A port that touches it must keep the quarantine path and the revocation checks.
- Only publication sites with a fence or arbiter check refuse late work. A new publication site in work that a leased call starts needs its own check.
- Revisit if the limits fill in practice, or if a publisher that runs off the main actor appears.
