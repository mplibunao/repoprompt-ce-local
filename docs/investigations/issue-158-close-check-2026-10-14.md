# Investigation: Can issue #158 be closed?

> Investigation report, observed 2026-10-14 on `main` at `0f371cb6`. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary
Issue #158 is fixed on `main` (`0f371cb6`). The fix, `1603277e`, merged on 2026-10-08 in PR #156. In
`testPromptExportPhaseAndDeliveryTracesShareCanonicalIdentity`, the deadline `XCTAssertNil` (test lines 1343–1351) now
runs after a bounded wait for the same request's `transport_write_completed` trace. The server emits that trace only
after it clears the deadline. Hosted CI agrees: the assertion failed twice in the two days before the fix and in none of
29 executions after it. No production change is needed.

The neighbouring test `testPipelinedSameToolDeadlinesFollowExactRequestIdentityWhenAdmissionReverses` has the same
unordered read at lines 1904–1910. It has never failed, and no issue tracks it.

## Question
Issue #158 ("Export-watchdog test asserts the delivery deadline is cleared before the server has cleared it") reports a race in
`MCPExportWatchdogIntegrationTests.testPromptExportPhaseAndDeliveryTracesShareCanonicalIdentity`
(`Tests/RepoPromptTests/MCP/Control/MCPExportWatchdogIntegrationTests.swift`). An owner comment dated 2026-10-14
says the repair is already on `main` in commit `1603277e` ("test(mcp): check the export deadline after the response is on the wire")
and recommends closing. This investigation checks that claim independently.

## Symptoms (from the issue)
- Hosted CI run 37425605580, root shard 2, branch `bugfix/143-context-builder-cross-tab-concurrency` at `103b0b6d`:
  `XCTAssertNil failed: "Deadline(instant: 300.0 seconds, now: (Function))" - workspace_context`, 10.39 s.
  The same connection's `prompt` case passed the same assertion a few milliseconds earlier.
- Reported mechanism: the test's client reads the response off the socket on its own queue and resumes `callTool`
  before the server thread in `UnixSocketMCPTransport.send` reaches `completeServerFrame` (which runs after `writeAll`).
  The test asserted the deadline was gone right after `callTool` returned (issue cites line 1287), with no ordering
  against the server-side clear.
- Requested repair: move the `XCTAssertNil` block to after the test's existing bounded wait for this request's
  `transport_write_completed` trace, which is emitted after the clear in the same synchronous stretch.

## Hypotheses
- **H1 (fixed):** `1603277e` is an ancestor of `origin/main` and moves the deadline assertion after the bounded
  `transport_write_completed` wait for the same request, without weakening it.
- **H2 (residual race):** The same early-observation pattern survives elsewhere: another loop iteration/tool case
  in this test, a sibling test in the same file, or a production reordering after the fix that breaks
  "clear happens-before `transport_write_completed`".
- **H3 (still flaking):** Hosted CI has failed this test (or this assertion) since the fix landed.

## Repository policy on closing
No repository document defines an issue-closure policy. `CONTRIBUTING.md:5` says work is tracked as issues and
pull requests on `mplibunao/repoprompt-ce-local`; `.agents/skills/rpce-maintainer-guidance/SKILL.md` ("Stage scope
deliberately") requires deferred work to stay in an issue or explicit follow-up. Closing is MP's call; this report
supplies the evidence.

## Background / Prior Research

### Git archaeology (explore probe; spot-checks pending in the Investigation Log)
- `1603277eb9ccf3cddeb087d9b3299b4b1d433514` (2026-10-07 07:42 UTC, "test(mcp): check the export deadline after the
  response is on the wire") is an ancestor of `origin/main` (`145c0160`). It reached `main` through merge commit
  `b101eb5650a99b5497b7496c5f6643bf2d20d340` (2026-10-08 09:40 UTC), PR #156 "Run Context Builder in different tabs
  of one window at the same time". The commit says "Part of #143"; neither it nor the merge mentions #158, which is why
  GitHub did not auto-close the issue.
- The diff is test-only: it deletes the `XCTAssertNil(MCPExportResponseDeliveryDeadlineRegistry.shared.deadlineForTesting(...))`
  block from right after the `callTool`/formatting-gate teardown (old lines ~1287–1294) and re-adds it, unchanged in
  condition, message (`testCase.requestedName`), and key (`connectionID: endpoint.connectionID.uuidString`,
  `connectionGeneration: 1`, `requestID: .number(Int64(requestID))`), after the existing
  `XCTAssertTrue(transportWriteCompleted, "... not recorded within 10 seconds")`. The 10-second wait budget is unchanged.
  A comment was added: "The server clears the deadline in the same stretch that then emits this trace."
- No commit after `1603277e` on `origin/main` touches the test file or
  `Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift` (which also defines
  `MCPExportResponseDeliveryDeadlineRegistry`, line 165).
- Earlier related fix `1ce14bc7` (2026-09-11, issue #13) added the bounded 10-second wait for the exact-request
  `transport_write_completed` trace before checking delivery events; it did not move the registry assertion.
- Verified directly: `git rev-parse 1603277e^` = `b215bbf5cc5d05e80493fd65dff18d39d9b1faec`.

### Hosted CI history (explore probe, attempt-aware; one claim verified directly)
- Pre-fix failures of this exact assertion (both on `bugfix/143-context-builder-cross-tab-concurrency`):
  - Run 37425605580, **attempt 1**, job 112144422722 "Build and Test (root shard 2)", SHA `103b0b6d`, 2026-10-06:
    `MCPExportWatchdogIntegrationTests.swift:1287: error: ... XCTAssertNil failed: "Deadline(instant: 300.0 seconds, now: (Function))" - workspace_context`,
    test failed after 10.390 s (verified directly from the job log, log lines 57113–57114). Attempt 2 of the run was a
    rerun that passed, which is why the run now shows `success`.
  - Run 37571828961, attempt 1, SHA `b215bbf5` (the fix's parent), 2026-10-07T04:30Z: same assertion, `- prompt` case.
- Post-fix: 44 runs created on or after 2026-10-07 across all branches, all head SHAs present locally; 4 had a second
  attempt and every earlier attempt's failed jobs were grepped. 31 run heads contain `1603277e`; **29 completed an
  execution of `MCPExportWatchdogIntegrationTests`, with no failure of the class in any attempt.** The only other failures
  in the window were unrelated (`ContextBuilderTabAdmissionTests` in run 37589749507, and non-matching root-shard
  failures in runs 38497236976, 38482156681, 38459420719 attempt 1).
- Caveat: zero failures in 29 executions is consistent with a fix but cannot prove a race is gone; the source-ordering
  argument below carries that.

## Investigator Findings

Checked on `main` at `0f371cb6`, which has `145c0160` as an ancestor. The working tree matches HEAD for the three files
involved. `UnixSocketMCPTransport.swift` and `MCPConnectionManager.swift` are identical at both commits at every line
cited below. The test file gained 131 lines before the sibling test in `7041fdce` ("write prompt exports into the
session's bound worktree"). The sibling test now starts at 1802 instead of 1671, and its lines 1760, 1763, 1764 and
1773–1779 are now 1891, 1894, 1895 and 1904–1910. `waitUntil` moved from 2522 to 2777 and `PersistentMCPTestSocketClient`
from 3332 to 3587. The #158 test (1213–1351) did not move. Lines below are HEAD lines. The SDK source is
`.build/checkouts/swift-sdk/Sources/MCP/Server/Server.swift`, called `Server.swift` below. An "actor hop" is a call that
must run on another actor's executor. The calling task suspends until that actor is free. Explore probes enumerated the
`await`s on request 1's path, the transport write path, the SDK dispatch model and the tracer callers. Every file:line
below that a verdict depends on was re-read directly.

### Sibling test (`testPipelinedSameToolDeadlinesFollowExactRequestIdentityWhenAdmissionReverses`): the race stands

**Verdict: no happens-before edge from request 2's clear to the read at 1904–1910.** The counter-argument needs both
(a) and (b). (a) holds and (b) fails.

**(a) holds: the last write and the clear are one non-suspending stretch on the transport actor.**
- `UnixSocketMCPTransport` is an `actor` (`UnixSocketMCPTransport.swift:374`) with no `unownedExecutor` or
  `SerialExecutor` in the file, so it runs on the default serial executor.
- `send` (665 ff.) is actor-isolated. `writeAll` (1162–1241) is a `private func … async throws` on the same actor and
  contains no `await`: the syscall is `Darwin.write` at 1202–1204; EAGAIN goes to `waitForSocketWritable` (1243 ff.),
  a synchronous `throws` method that blocks the thread in `poll(2)` (1275) and returns on `POLLOUT` (1300–1301),
  so it never suspends the task. After the last successful write the loop runs `dropFirst` (1234), `Date()` (1235),
  the debug hook (1236–1238; declared at 470 as a synchronous `@Sendable (Int) -> Void`), the deadline check (1239),
  exits and returns. The same-actor `await writeAll` at 750 cannot hop or suspend because the callee never suspends.
- Back in `send`, on the success path: the deadline check (751), `responseDeliveryGate.recordDeliveredServerFrame`
  (766; synchronous, parses the frame and takes an `NSLock`, `MCPDomainResponseDeliveryTracker.swift:51–70`),
  `lastActivityTime` (767), `if let timelineConnectionID` (768), `completeServerFrame` (769–773; parses the frame at
  339–342 and removes the keys under `lock.withLock` at 343–351), then the `transport_write_completed` trace (775).
  None of these is an `await`.
- Each accepted connection has its own transport: the only construction is
  `BootstrapSocketConnectionManager.swift:147–152`, from the accepted FD, and `timelineConnectionID` is that
  connection's id (`UnixSocketMCPTransport.swift:541`). Both pipelined requests share it.

**(b) fails: nothing on request 1's path from the gate to the formatting hook runs on that transport actor.**
- The `tools/call` closure is registered at `MCPConnectionManager.swift:11378` on `ServerNetworkManager`, an `actor`
  (450). The SDK runs the closure in a per-request `Task` (`Server.swift:629–651` `enqueueRequest`, then the handler task
  at 1203–1225, awaited at 1236), so the closure body is not actor-isolated and every `await self.…` in it hops to
  `ServerNetworkManager`, not to the transport.
- The transport is a private field of `BootstrapSocketConnectionManager` (line 83). `ServerNetworkManager` can reach it
  only through that object's methods, and the ones that await the transport are `closed`, `ingressSnapshot`,
  `closeSnapshot`, `disconnect`, `secondsSinceLastActivity`, `responseDeliverySnapshot`,
  `waitUntilResponseDeliveryDrained` and `send` (lines 182, 184, 229, 232, 340, 359, 420, 434, 454, 468, 472, 476, 480,
  499, 523, 567) plus `server.notify` (397, 560), which also ends in `transport.send` (`Server.swift:670–683`). A scan
  of `MCPConnectionManager.swift:11431–13524` for calls to those members and for `connections[`, `connection.`,
  `.notify(`, `server.`, `transport.`, `sendProgress`, `sendMCPProgress`, `deliverMCPProgress` and
  `isViableForRetention` finds one hit, `await self.connections[connectionID]?.capabilityToken` at 12218, and
  `capabilityToken` is `nonisolated` (`BootstrapSocketConnectionManager.swift:97`), so it does not hop even to the
  connection actor.
- The `await`s on the path target, in order: `requestTimelineConnectionGeneration` (11438; a dictionary read on the
  manager, 2633–2635), `toolExecutionWatchdogEnvironment` (11581), `bindingResolver.resolveLogicalContextBinding`
  (11695; `MCPBindingResolver` is a struct, `MCPBindingResolver.swift:25`, with no transport reference),
  `effectivePolicyState` and `domainHost.evaluate*CallPolicy` (11771–11851; the domain host is defined in
  `RepoPromptDomainRuntime` and has no transport), `MainActor.run` (11928), `connectionCallLimiterResolution` (11959),
  `withConnectionCallPermit` (12051; 14759–14815, the limiter's `withPermit`), routing lookups on the manager and
  `MainActor` (12128–12313), `domainHost.acquireMutationResourceAdmission` (12334), `fireToolCalledObservers` (12509;
  3708 ff.), `runPurpose` and `recordToolCall` (12534, 12542; 14624–14651), `ensureTabBoundForRunIfPossible` (12569;
  11132 ff., `MainActor.run`), `MCPToolExecutionHandlerPhaseContext.report` (12593), the authority checks (12634–12647,
  12758–12771; 14733–14744 and the `MainActor` check at 2234–2243), the task-local wrappers (12777–12789), the
  prompt-export host bridge (12898–12960, an in-process `PromptExportProviderEntryBridge`),
  `MCPToolExecutionWatchdog.execute` (12968), the operation override (13455–13457, which returns the test's value and
  skips `domainHost.invoke` at 13460), `captureWindowToolDispatchIdentity` (13475; 2216–2232), `withWindowToolOwnership`
  (13498; 2283–2310), `dispatchResolvedProvider` (13512; 12630 ff.), `reportPromptExportPostProviderPhase` (13522;
  12588–12628, which records a phase and emits an `MCPToolExecutionTracer` event, not a notification), and the hook at
  13524.
- The one progress path before formatting, `domainHost.beginRequestProgress` (11900), runs only when
  `params._meta?.progressToken` is present. The test client sends `name` and `arguments` only (`callTool`, test file
  3559–3571), and `beginRequestProgress` itself only records state (`MCPDomainHost.swift:360–383`).
- The SDK does not order these either. Response 2 is written by an unstructured `Task` inside `sendResponseData`
  (`Server.swift:523–526`; `race.resolve(.sent)` runs after `connection.send` returns, and the caller waits on
  `ResponseSendRace`, 15–34, at 542). Handler 1 sits in its own task awaiting the test gate
  (`MCPExecutionIgnoringCancellationGate`, test file 2949) and, once released, never touches the `Server` actor until it
  returns its result.

The permitted interleaving, now source-backed:
1. The kernel accepts the last byte of response 2 inside `Darwin.write` (1202).
2. The client's reader thread (`readerLoop` in `PersistentMCPTestSocketClient`, 3587 ff.) reads the frame and resumes
   the `callTool` continuation for request 2; `activeSecondTask.value` returns and the test resumes at 1891.
3. The test releases the admission gate (1894); handler 1 runs 11438 through 13524 and enters the formatting gate; the
   test resumes at 1895, unwraps request 1's deadline (1896–1902) and reads request 2's key at 1904–1910.
4. Only now does the transport thread run 1234–1241 and 751–773 and remove the key.

The window in which the key is still installed after the bytes are visible to the client is the transport thread's work
between 1202 and 351. That work is two small JSON inspections of the frame (`messageObjects(in:)` at
`MCPDomainResponseDeliveryTracker.swift:52` and `JSONRPCBridgeFrameInspector.inspectPermissively` at
`UnixSocketMCPTransport.swift:339`) and two `NSLock` sections, tens of microseconds for this frame unless the thread is
descheduled.

**Where this contradicts the report.** The H2d conclusion calls the sibling "a much wider window". The window is the
same as #158's: the key stays installed for the same transport stretch. What differs is how much must happen inside it
before the read. The #158 test before its fix needed two cross-thread wake-ups (reader thread, then the `callTool`
continuation) and a registry read. The sibling needs those plus a gate release, the whole 11438-to-13524 traversal with
its dozens of hops to `ServerNetworkManager`, `MainActor` and the domain host, a second gate hand-off and another test
resume. Its exposure is strictly smaller than #158's pre-fix exposure. It is reachable only when the transport thread is
preempted inside that stretch for longer than the whole chain, which is plausible on an oversubscribed CI shard and
consistent with zero observations.

**Smallest test-only repair.** Replace the point-in-time `XCTAssertNil` at 1904–1910 with a bounded wait on the registry:

```swift
let secondDeadlineCleared = await Self.waitUntil {
    MCPExportResponseDeliveryDeadlineRegistry.shared.deadlineForTesting(
        connectionID: endpoint.connectionID.uuidString,
        connectionGeneration: 1,
        requestID: .number(Int64(secondRequestID))
    ) == nil
}
XCTAssertTrue(secondDeadlineCleared, "request 2's deadline was not cleared within 10 seconds of its response")
```

The read still follows request 1's install, which the `firstDeadline` unwrap at 1896–1902 proves, so the property the
test is named for (request 1's claim and install leave request 2's key alone) is still exercised. The wait needs no
tracing and is immune to the tracer drop described below. Observable result: a keying or clearing defect (install and
clear disagreeing on connection id, generation or request id, or request 1's claim disturbing request 2's key) leaves the
key in place, the wait runs its full 10 seconds and the test fails with that message; a correct clear returns on the
first poll with no delay; the interleaving above can no longer fail the test. The alternative is the #158 shape
(enable `enableMCPResponseDeliveryTrace`, reset the tracer, and wait for request 2's `transport_write_completed`), which
is more code and inherits the tracer-drop hazard.

### Tracer drop in the #158 test: reachable but narrow, and it would show as the 10-second trace timeout

**Verdict: reachable only through the test's own `debugEventSnapshot()` critical section, with a duty cycle on the
order of 10⁻⁵; a drop fails `XCTAssertTrue(transportWriteCompleted, …)` at 1339–1342 after 10 seconds, not the
`XCTAssertNil` at 1343–1350.**
- `emit` (`JSONRPCBridgeLedger.swift:301–322`) returns early unless `successTracingEnabled` (291–299; the test sets
  `enableMCPResponseDeliveryTrace` at 1222–1233), then `guard lock.try() else { return }` at 310. While holding the lock
  it appends to `debugEvents` (313–315; capped at 20000 events, which the test resets at 1243 before each case) and
  calls `BestEffortStderrWriter.writeNonBlocking` (321). That writer only try-locks (`writeLock.try()` at
  `BestEffortStderrWriter.swift:61`, `ftrylockfile(stderr)` at 65), makes a handful of `fcntl` calls and one
  `Darwin.write` on a non-blocking descriptor (71–113), and drops unwritten bytes instead of waiting, so an emitter holds
  the tracer lock for a few syscalls.
- `debugEventSnapshot` (331–335) takes the lock with a blocking `lock()` and returns the array. Swift arrays are
  copy-on-write, so the critical section is a retain and a return; the `.contains` scan at 1335–1337 runs after the lock
  is released. `waitUntil` (2777–2790) polls every 10 ms.
- Who can hold the lock at the instant the transport thread emits `transport_write_completed` (775) for the test's
  request: the poller inside 332–334, or another in-process emitter. The same request's earlier events
  (`handler_result_ready` at `MCPConnectionManager.swift:13114–13134`, `sdk_decode_completed` at 11483–11496,
  `sdk_encode_completed` at `UnixSocketMCPTransport.swift:743`, `transport_write_started` at 749) are emitted earlier on
  the same thread; the bridge emitters in `Sources/RepoPromptMCP/main.swift` run in the CLI process; the test issues one
  request at a time on one endpoint; and `debugEventSnapshot` has no other caller in the repository. The poller is the
  only realistic contender, and its section is sub-microsecond once per 10 ms.
- The asymmetry: the poller never loses, because its `lock()` blocks; only emitters drop. The copy an append pays while
  the poller's snapshot is still alive lengthens the emitter's own hold, which would only matter to a second concurrent
  emitter, and there is none in this test.
- Presentation: the request's `transport_write_completed` has a single producer (775, one event per recorded response
  at 711–733), so a drop means `waitUntil` runs its full 10 seconds, the `XCTAssertTrue` at 1339–1342 fails with
  "transport_write_completed trace was not recorded within 10 seconds", and the relocated `XCTAssertNil` at 1343–1350
  passes because the deadline was cleared long before. CI would show that assertion line and a test duration at least
  10 seconds longer than a passing run, which distinguishes it from #158's `XCTAssertNil failed: "Deadline(…)"` at the
  registry read. The probability per case is on the order of the poller's duty cycle, so the 29 clean post-fix
  executions say nothing about it either way, and no tracer change is warranted on this evidence.

## Investigation Log

### Phase 2 — context_builder and oracle first assessment
`context_builder` (run through `rpce-cli` after two MCP attempts returned "Tool execution was cancelled" with no
output) selected the full test file, `UnixSocketMCPTransport.swift`, `MCPRequestTimelineRegistry.swift`,
`MCPRequestTimelineIdentity.swift`, slices of `JSONRPCBridgeLedger.swift` and `MCPConnectionManager.swift`
(tools/call entry 11414–11490, install 11595–11665, formatting hooks 13505–13550 and 13670–13705), and this report.
Oracle verdict:
- The #158 race is repaired for both cases (`prompt`, `workspace_context`): clear and trace emission share one
  non-suspending stretch; the matcher anchors on this iteration's request id, connection id, and ordinal; the trace
  store is reset between cases; the pre-write `XCTUnwrap` (around 1268–1275) proves the test reads the installed key.
- The neighbouring test's second-request `XCTAssertNil` (1773–1779) has no ordering edge from that request's clear.
  Permitted interleaving: the transport writes response 2 and has not yet cleared; the client receives it and the test
  resumes; the test releases request 1, which reaches formatting; the test reads request 2's deadline, still present;
  then the transport clears it. Source-confirmed gap; never observed in CI.
- Trace drop on tracer-lock contention can produce a false failure at the "not recorded within 10 seconds" check,
  never a false pass. No tracer change recommended without evidence.
- `MCPRequestTimelineRegistry.completeResponses` runs after `transport_write_completed`, so that trace would not
  prove timeline cleanup; no test in the file asserts timeline-entry removal after client receipt.
- No production change is needed for #158.

### Orchestrator spot-checks — fix placement and server ordering (H1, H2a–c, H2e, H3)
**Hypothesis:** The relocated assertion is ordered after the server-side clear for every case.
**Evidence:**
- Test, current `main`: the bounded wait `Self.waitUntil { MCPResponseDeliveryTracer.debugEventSnapshot().contains { $0.phase == "transport_write_completed" && matchesRequestIdentity($0) } }`
  is at `MCPExportWatchdogIntegrationTests.swift:1334–1338`, its `XCTAssertTrue` at 1339–1342, and the
  relocated `XCTAssertNil(deadlineForTesting(...))` at 1343–1351. `matchesRequestIdentity` (1329–1333) matches
  JSON-RPC id, connection id, and request ordinal, so a trace from another case or request cannot satisfy it.
- Transport, `UnixSocketMCPTransport.swift`: `await writeAll` at 750, then, with no suspension,
  `MCPExportResponseDeliveryDeadlineRegistry.shared.completeServerFrame(...)` at 769–773, then
  `emitResponseWriteTrace(phase: "transport_write_completed")` at 775. The failure path (751–764) emits
  `transport_write_failed`, never `transport_write_completed`.
- `"transport_write_completed"` has a single producer, `UnixSocketMCPTransport.swift:775` (other hits are consumers:
  `MCPConnectionManager+DebugDiagnosticsApplyEditsRebaseLatency.swift:1101` and the test).
- Visibility: `completeServerFrame` removes the key synchronously under the registry `NSLock`
  (`UnixSocketMCPTransport.swift:335–352`); `MCPResponseDeliveryTracer.emit` appends under the tracer `NSLock`
  (`Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift:301–321`); `debugEventSnapshot` reads under the same lock
  (331–335); `deadlineForTesting` reads under the registry lock (`UnixSocketMCPTransport.swift:296–308`). Seeing the
  event therefore happens-after the removal, so the following registry read observes it.
- Keying: the test's earlier `XCTUnwrap(deadlineForTesting(...))` (around 1268–1275) with the same key proves the
  install key matches, and the 29 post-fix passes show the clear key (`timelineConnectionID`) matches too; a mismatch
  would fail every run, not intermittently.
- The trace is emitted even when `timelineConnectionID` is nil (clear guarded by `if let` at 768), but in that case
  the deadline would never be cleared and the test would fail deterministically, which is a real defect the test is
  meant to catch, not a race.
**Conclusion:** H1 confirmed for the #158 test. H2(a), H2(b), H2(c), H2(e), H3 eliminated. Two qualifications from
the Phase 2 oracle review: `XCTAssertTrue(transportWriteCompleted)` is non-fatal, so on a timed-out wait the
`XCTAssertNil` still runs, but the test has already failed and cannot pass; and a failed send can still remove
deadlines through connection teardown (`tearDownSocket` → `removeConnection`), which never emits
`transport_write_completed` and so cannot satisfy the wait.

### Orchestrator spot-check — sibling readers of the registry (H2d)
**Hypothesis:** Another test reads the registry right after a client-observed response without a server-side ordering event.
**Evidence:** `deadlineForTesting` appears only in `MCPExportWatchdogIntegrationTests.swift` (lines 1269, 1345, 1746,
1753, 1766, 1774). In `testPipelinedSameToolDeadlinesFollowExactRequestIdentityWhenAdmissionReverses`, line 1760
awaits `activeSecondTask.value` (client has the second response) and lines 1773–1779 assert
`XCTAssertNil(deadlineForTesting(... secondRequestID))`. Between them the test only releases the first request's
admission gate (1763) and waits for the first request to reach formatting (1764); no wait on the second request's
`transport_write_completed`. `git blame` dates these lines to `7b47d9e` (2026-09-05). The other three reads in that test are ordered by gates (first request blocked before
claim; both installs precede the formatting hooks).
**Conclusion:** Same race class as #158, confirmed by the pair under Investigator Findings. On `0f371cb6` the lines
are 1891 (`activeSecondTask.value`), 1894–1895 (gate release and formatting wait) and 1904–1910 (the read).

### Orchestrator spot-check — trace drop under contention (new lead, separate from #158)
**Evidence:** `MCPResponseDeliveryTracer.emit` uses `guard lock.try() else { return }`
(`JSONRPCBridgeLedger.swift:310`), so a success trace is dropped if any thread holds the tracer lock at that moment,
including the test's own `debugEventSnapshot()` polling. A dropped `transport_write_completed` would fail the #158 test
at the "not recorded within 10 seconds" `XCTAssertTrue` (1339–1342), not at the deadline assertion.
**Conclusion:** Not the #158 failure mode. The pair found the drop reachable only through the test's own
`debugEventSnapshot()` polling, with a very small probability per case (see Investigator Findings).

## Root Cause
The original test treated the client receiving the response as proof that the server had finished its post-write
bookkeeping. `PersistentMCPTestSocketClient` (test file 3587 ff., `readerLoop` at 3737) resumes `callTool` from its own
read queue as soon as a full frame arrives. The server clears the deadline only after `writeAll` returns
(`UnixSocketMCPTransport.swift:750`, then `completeServerFrame` at 769–773). If the transport thread is preempted in
between, the test reads the deadline before the clear. `1603277e` moves the read after the `transport_write_completed`
trace (775), which the same thread emits after the clear. Because the test reads the trace under the tracer lock and
the deadline under the registry lock, seeing the trace means the clear is visible too.

The neighbouring test waits for request 1 to reach its formatting hook before reading request 2's deadline. Request 1's
path runs on `ServerNetworkManager`, `MainActor` and the domain host, never on the transport actor, so it gives no
ordering against request 2's clear. Its chance of failing is smaller than #158's was before the fix, because the test
must do far more work inside the same window.

## Recommendations
1. **#158: close as fixed.** The commit referenced "Part of #143" only, so GitHub didn't close the issue.
2. **File a separate issue for the neighbouring test, as a port.** Filed as #174; #158 closed as completed. Upstream already fixed this read in upstream PR 1015
   (commit `bbb1c972`, upstream test file around line 2324): right after response 2 arrives, the test calls
   `await endpoint.connectionManager.responseDeliverySnapshot()`. That call runs on the transport actor
   (`BootstrapSocketConnectionManager.swift:475–477`). The transport's last write and the clear run in one actor turn
   with no suspension, so the call returns only after the clear. The distribution has the same API, so the port is one
   line after test line 1891. The rest of upstream PR 1015 (subagent waits, `read_file` formatting) is unrelated. A
   bounded `Self.waitUntil` until request 2's deadline is `nil`, followed by `XCTAssertTrue` (code under Investigator
   Findings), also works but departs from upstream's mechanism. A keying or clearing defect still fails it after 10 seconds. A
   correct clear passes on the first poll. To show the repair closes the window, a throwaway run can stall the transport
   thread after its last write: `debugSetAfterWriteProgressForTesting` (`UnixSocketMCPTransport.swift:1102`, called at
   1237 before the clear) is already used at test lines 2249 and 2330 on transports those tests build. Nobody has
   checked whether the persistent fixture exposes its server-side transport.
3. **No tracer change.** A dropped `transport_write_completed` would fail the "not recorded within 10 seconds" check
   at test lines 1339–1342 and make the test about 10 seconds slower, which is distinguishable from #158. Revisit only
   if that failure appears in CI.

### Maintainer-guidance check
- **User impact and invariant:** no spurious CI failures, while a deadline left after delivery still fails the test.
- **Root-cause confidence:** confirmed for #158 (source order plus CI history) and for the neighbouring gap (source
  only, never observed).
- **Authority:** `MCPExportResponseDeliveryDeadlineRegistry` and the transport's clear at 769–773.
- **State-safety risks:** none. The change is test-only.
- **Scale and observability risks:** none.
- **Recommended scope:** close #158 and file the neighbouring test as an issue.
- **Validation boundary:** source ordering and hosted CI history. No new test runs.

## Preventive Measures
- Assert on server-side cleanup only after an event the server emits after that cleanup, or with a bounded wait on the
  state itself. Neither client receipt nor another request's progress orders anything against the server's clear.
- Reference the issue a commit fixes in its pull request, so GitHub closes the issue on merge.
