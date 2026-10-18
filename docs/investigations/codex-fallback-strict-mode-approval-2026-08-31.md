# Investigation: Codex fallback queue strict-mode approval failures

> Investigation report, observed 2026-08-31. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary

The three `CodexFallbackFIFOTests` failures are a high-confidence test-isolation defect, not evidence of a first-in, first-out (FIFO) runtime defect. The tests request the supported non-strict `.continueWithoutHooks` path but inherit the user's persisted strict-mode setting through `GlobalSettingsStore.shared`. The coordinator correctly rejects that decision before any queue claim, start, trust write, attachment consumption, or successor dispatch.

## Symptoms

- `testFollowUpDuringInitialHookDiscoveryCoalescesGateAndPreservesRun` throws `strictModeRequiresApproval` from `CodexAgentModeCoordinator.swift:965`.
- `testIdlePumpFallbackWaitsForHookReviewBeforeClaimingHeadOrAttachments` throws the same error.
- `testTerminalSuccessorFallbackWaitsForHookReviewBeforeSuccessorClaim` throws the same error.
- An isolated class run reports exactly 3 failures out of 30 tests.
- A source-clean detached control at a local commit reports the same three failures, excluding the patch under investigation as the cause. The control reused the same persisted user settings, so it doesn't independently isolate settings.

## Background / Prior Research

- Upstream issue 665 documented the original fail-open Codex project-hook behavior. It closed on August 20, 2026 when upstream PR 678 merged as `18318807a9bb7fce346951fcdf582cc459dda21a`.
- Upstream PR 678 and its review explicitly cover fallback idle-pump gating, follow-ups during initial hook discovery, terminal-successor fallback, and binding queued fallback work to the hook-gate owner until terminal completion.
- The strict guard was introduced in `2d5936cc7321ac0edde34dd84db2f1ae5490b4c5`. The idle-pump and terminal-successor tests were introduced in the same commit. The follow-up coalescing test was added in `f230cd1e48cf23e1082332ed719d848cc0fe8103`; queued-owner binding followed in `788d0edbb03f3d192979025f08677cd9ba453dd4`.
- The current production and test files match the final upstream PR 678 feature snapshot. Later changes through the current baseline do not alter the strict guard or the three failing test bodies.
- Production defaults strict mode to false when the optional persisted setting is absent. Dedicated hook-approval tests inject an explicit false default and enable strict mode only in strict-mode cases. `CodexFallbackFIFOTests.makeRunningSession` does not inject a hook-settings provider and therefore reads `GlobalSettingsStore.shared`.
- Each failing FIFO test supplies an unresolved hook inventory and resolves the review with `.continueWithoutHooks`. Persisted `codexHookApprovalStrictModeEnabled=true` makes the coordinator correctly reject that decision with `strictModeRequiresApproval`.
- Upstream PR 837 is open as of August 31, 2026 and states that it supersedes upstream PR 678 with a current-main isolated hook-compatibility implementation. It fails closed without a bypass.
- Related reports in the OpenAI Codex tracker concern Codex trust writes or approval signaling rather than CE FIFO scheduling: Codex issues [22847](https://github.com/openai/codex/issues/22847), [38371](https://github.com/openai/codex/issues/38371), [23465](https://github.com/openai/codex/issues/23465), and [28833](https://github.com/openai/codex/issues/28833).
- GitHub deduplication found no exact untracked runtime issue. The evidence supports a candidate test-fixture fix, not a new runtime issue or an upstream FIFO duplicate.
- The July 2026 hook spike confirmed that trusted hook state is dynamically reloadable, hook trust writes require app-global serialization, and project trust gates hook discovery.

## Investigator Findings

### Verdict

The context-builder conclusion is supported with high confidence: this is a test-isolation defect in `CodexFallbackFIFOTests`, not evidence of a FIFO runtime defect. The three tests assume non-strict `.continueWithoutHooks` behavior but obtain strict mode from the user's live persisted global settings because their shared fixture does not inject `CodexHookApprovalSettingsProviding`.

### Current-checkout reproduction

- Reproduction context at the start of this investigation: branch `bugfix/887-qualified-read-peer-stall` at a local head. `git status` reported pre-existing untracked entries and no tracked modification.
- Command: `./conductor test --filter CodexFallbackFIFOTests --async --request-key <key> --json`.
- Result: 30 tests executed, exactly 3 unexpected failures, in 3.282 seconds. All three throw `strictModeRequiresApproval` at `Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:965`:
  - `testIdlePumpFallbackWaitsForHookReviewBeforeClaimingHeadOrAttachments`
  - `testFollowUpDuringInitialHookDiscoveryCoalescesGateAndPreservesRun`
  - `testTerminalSuccessorFallbackWaitsForHookReviewBeforeSuccessorClaim`
- The previously recorded clean control has the same exact 3/30 outcome, which excludes the changes under investigation as the trigger.

### Settings and workspace resolution

- `CodexFallbackFIFOTests.makeRunningSession` constructs `AgentModeViewModel` with only a controller factory; it supplies neither `testCodexHookApprovalSettingsProvider` nor a workspace identity (`Tests/RepoPromptTests/AgentMode/Codex/CodexFallbackFIFOTests.swift:1496-1527`). A search of the complete test file finds no `testCodexHookApprovalSettingsProvider` or `CodexHookApprovalSettingsProviding` reference.
- The debug initializer accepts an optional test provider and otherwise injects `GlobalSettingsStore.shared` (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:1865,1921-1930`). It also sets `workspaceManager = nil` (`AgentModeViewModel.swift:1876-1883`). `lastKnownWorkspaceSnapshot` and `test_activeWorkspaceIDForSessionIndexOverride` are nil-initialized optionals (`AgentModeViewModel.swift:692,701-704`), and `test_initializeRunService` only forces `runService` initialization (`AgentModeViewModel.swift:768-770`).
- Strict-mode lookup passes `activeWorkspaceIDForSessionIndexOwnership` (`Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:626-629`). For this fixture that property resolves to `workspaceManager?.activeWorkspaceID ?? lastKnownWorkspaceSnapshot?.id`, hence `nil` (`AgentModeViewModel.swift:18557-18564`). No workspace override can participate in these tests.
- `GlobalSettingsStore` checks a workspace override only when a non-nil workspace ID is supplied, then falls back to the global scalar; an absent global scalar defaults to false (`Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsManager.swift:1373-1387`).
- A non-mutating, field-limited `jq` read of `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json` during reproduction returned schema v4, lineage `repoprompt-ce.global-settings`, `codexHookApprovalStrictModeEnabled: true`, and `codexHookApprovalStrictModeWorkspaceOverrides: null`. The file's documented location is `Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift:3-10`. No setting was changed.

Therefore the effective value for all three fixtures is the live persisted global `true`, not a workspace override and not the code default of `false`.

### Guard and FIFO mutation ordering

Each failing test supplies an unresolved project-hook inventory and resolves the review with `.continueWithoutHooks` (`Tests/RepoPromptTests/AgentMode/Codex/CodexFallbackFIFOTests.swift:622-683,690-790,797-860`). The shared hook inventory is untrusted (`CodexFallbackFIFOTests.swift:1682-1698`).

The common control flow is deterministic:

1. `gateFirstTurnForProjectHooks` creates the pending review and suspends the owner on `codexHookReviewContinuation` (`CodexAgentModeCoordinator.swift:848-930`; continuation storage is at `:798-813`).
2. `resolveCodexHookReview` validates the pending request and binding, then checks strict mode for `.continueWithoutHooks` (`CodexAgentModeCoordinator.swift:937-965`).
3. With strict mode true, line 965 throws before `completeCodexHookReview` is called at lines 967-980.
4. `completeCodexHookReview` is the operation that clears the request, records the audit, publishes state, and resumes the suspended continuation (`CodexAgentModeCoordinator.swift:1200-1229`). None of those actions occurs on the throwing path.
5. Trust writes are exclusive to approval paths through `submitCodexHookApproval`; the controller write occurs only after the request transitions to `.submitting` (`CodexAgentModeCoordinator.swift:1058-1095`). `.continueWithoutHooks` never enters that function.

The FIFO-specific paths also gate before mutation:

- Idle-pump dispatch awaits the hook gate before `claimCodexFallbackHead` (`CodexAgentModeCoordinator.swift:3185-3220`). Claiming is what activates the attachment reservation, removes the queue head, installs `codexFallbackDispatchInFlight`, and marks the run active (`CodexAgentModeCoordinator.swift:3139-3181`). Provider start follows the claim, and attachment consumption is recorded only after a successful start (`CodexAgentModeCoordinator.swift:3223-3266,5189-5197`).
- Initial-turn dispatch awaits the gate before tracked-turn creation or `controller.startUserTurn` (`CodexAgentModeCoordinator.swift:6552-6585`). Because the review continuation is not resumed, neither the initial start nor the coalesced follow-up release occurs.
- Terminal-successor dispatch awaits the gate before changing the queued entry to `.eligibleForSuccessor` (`CodexAgentModeCoordinator.swift:3659-3700`). The later publication callback performs the actual successor claim (`CodexAgentModeCoordinator.swift:3710-3751`).

The tests' pre-resolution assertions independently confirm the suspended state: zero starts, a still-queued head, no dispatch in flight, unchanged run-attempt identity, and idle/detached attachments (`CodexFallbackFIFOTests.swift:662-670,839-846`; the follow-up case confirms only one hook discovery at `:730-740`). The strict throw occurs after those assertions but before any release. Queue insertion, review creation, attachment detachment, and status publication do occur before resolution; no claim, start, attachment consumption, trust write, or successor dispatch can occur between the strict guard and the throw.

### Independent discriminator tests

Two existing focused tests prove the setting-dependent behavior without depending on the user's persisted state. Their fixture injects `HookApprovalFakeSettingsProvider(enabled: false)` by default (`Tests/RepoPromptTests/AgentMode/Codex/CodexAgentModeCoordinatorHookApprovalTests.swift:1045-1057,1207-1217`).

- Non-strict release: `testContinueWithoutHooksBlocksFirstTurnThenReleasesBindingOnce` (`CodexAgentModeCoordinatorHookApprovalTests.swift:59-88`) proves zero starts while gated, then `.continueWithoutHooks` resumes the first turn. Result: 1/1 passed in 0.095 seconds.
- Live strict rejection: `testStrictModeIsReadLiveAndRejectsContinueWithoutMutation` (`CodexAgentModeCoordinatorHookApprovalTests.swift:156-187`) changes the injected provider from false to true after the request is pending, asserts `strictModeRequiresApproval`, the same pending request, zero starts, and no trust calls, then changes it back to false and completes. Result: 1/1 passed in 0.090 seconds.

There is no existing test that reruns the three FIFO hook scenarios with an explicit false provider. The direct false-provider FIFO discriminator is therefore a coverage gap; the existing hook-approval test proves the common gate behavior, not all three FIFO state-machine assertions under explicit non-strict injection.

### Product contract and upstream PR 837

The checked-out product intentionally enforces strict mode at every exposed boundary:

- The SwiftUI hook card omits `Continue Without Hooks` when strict mode is enabled and dismisses an already-open confirmation if strict mode changes live (`Sources/RepoPrompt/Infrastructure/UI/Agent/CodexHookReviewCard.swift:9-13,75-84,117-181`).
- MCP interaction options omit `continue_without_hooks` in strict mode (`AgentModeViewModel.swift:5984-5997`), and an attempted strict response is rejected before coordinator resolution (`AgentModeViewModel.swift:8687-8699`).
- The coordinator rechecks the live value, so stale UI or MCP state cannot bypass the guard (`CodexAgentModeCoordinator.swift:959-965`).

Upstream PR 837 remained open with seven commits when checked on August 31, 2026. Its description says it supersedes upstream PR 678 with a current-main isolated compatibility implementation and removes the continue-without-hooks bypass entirely. Because it is open and not part of this checkout, it is external future/superseding work; it does not redefine the current local contract or explain these current test failures.

### Eliminated hypotheses

- **FIFO claim-before-approval regression:** eliminated by source ordering and the three pre-resolution state assertions. Every relevant claim path is downstream of the suspended hook gate.
- **Attachment-consumption race:** eliminated. The reservation is detached while queued, is reactivated only during claim, and is consumed only after provider start succeeds.
- **Unexpected hook trust mutation:** eliminated. The failing decision never enters the trust-write function; the strict test also observes zero trust calls.
- **Workspace override contamination:** eliminated for these fixtures because the effective workspace ID is nil; the current persisted override map is also absent.
- **Regression from the patch under investigation:** eliminated by the pre-recorded clean control with the same exact failures.
- **Upstream PR 837 contract change already present locally:** eliminated. The PR is still open; checked-out code retains the conditional non-strict bypass and strict guard.

### Ownership, severity, scope, and recommendation

- **Smallest ownership boundary:** the test fixture at `CodexFallbackFIFOTests.makeRunningSession`, specifically its missing hook-settings dependency injection. Production coordinator, queue, UI, MCP, and persistence logic agree on the strict-mode contract and should not be changed to make these tests pass.
- **Severity:** test-isolation/CI reliability defect. It deterministically makes the focused class and any encompassing suite red for users whose persisted global strict mode is true, but the evidence does not show a user-facing FIFO scheduling or data-loss defect.
- **Scope:** exactly the three FIFO tests that create unresolved hooks and choose `.continueWithoutHooks`; the other 27 class tests passed in the same run. The failure depends on mutable user state leaking into a unit-test fixture.
- **Recommended scope:** isolate the test fixture from `GlobalSettingsStore.shared` and add a direct explicit-false FIFO discriminator when source changes are authorized. Do not weaken the production strict guard.

### Maintainer-guidance check

- **User impact and invariant:** strict mode must keep the hook gate closed until approval; FIFO work must not claim or consume attachments before the gate releases.
- **Root-cause confidence:** confirmed for the current checkout; high-confidence test-isolation defect.
- **Authority:** `CodexHookApprovalSettingsProviding` as resolved by `GlobalSettingsStore` in production and an injected fake in unit tests.
- **State-safety risks:** weakening the coordinator guard would create a real strict-mode bypass; isolating the fixture avoids that risk.
- **Scale and observability risks:** none identified beyond deterministic suite contamination by user settings; the existing review/audit/UI/MCP surfaces remain observable.
- **Validation boundary:** the isolated FIFO class, the two focused hook-gate discriminator tests, and source-order inspection at the hook gate and claim sites.

### Remaining uncertainties

- The archived clean-control conductor job and its log artifact could not be rehydrated through the currently active conductor state (`job status` returned `unknown job`); their identifiers, checksum, commit, and exact 3/30 result were already recorded before this pair pass. The current-checkout result independently reproduces the same signature.
- Because this task prohibits source/test changes and user-setting mutation, the three FIFO scenarios were not rerun with an explicit false provider. No existing test provides that exact discriminating path. This gap affects completeness of the test proof, not the source-order classification.

## Investigation Log

### Initial assessment - Failure classification

**Hypothesis:** The failures could be a coordinator regression, stale fixture assumptions after strict-mode adoption, shared test contamination, or an expected contract change.

**Findings:** The patch under investigation is excluded by an exact clean detached control. The strict-mode guard and hook-approval test setup remain the leading boundary.

**Evidence:** The same named 3/30 failures occur at the same coordinator guard on the patched checkout and detached baseline commit.

**Conclusion:** Current-checkout reproduction, history, source-flow analysis, fixture comparison, and GitHub deduplication identify a test-isolation defect at the FIFO fixture's settings-provider boundary.

## Root Cause

`CodexFallbackFIFOTests.makeRunningSession` omits `CodexHookApprovalSettingsProviding`, so its `AgentModeViewModel` supplies `GlobalSettingsStore.shared` to the coordinator. The fixture has no active workspace identity. Strict-mode lookup bypasses workspace overrides and reads the persisted global value, which was `true` during reproduction.

All three affected tests create unresolved hooks and submit `.continueWithoutHooks`, a supported decision only when strict mode is false. `resolveCodexHookReview` reads strict mode live and throws `strictModeRequiresApproval` before `completeCodexHookReview` releases the suspended continuation. The idle-pump, initial/coalesced, and terminal-successor paths all await that continuation before their respective FIFO mutations. These failures show a policy rejection before queue mutation, not a queue-ordering, duplicate-start, attachment-consumption, or successor-claim defect.

The detached control excludes the patch's code delta but reused the same persisted setting. Independent focused tests prove the common non-strict release and strict rejection contracts; the exact three FIFO scenarios have not yet been rerun with an explicit false provider.

## Recommendations

1. Treat this report as a candidate test-fix for the root task; the current evidence doesn't justify a new runtime issue.
2. Isolate `CodexFallbackFIFOTests.makeRunningSession` with an explicitly injected non-strict hook-settings provider for scenarios that choose `.continueWithoutHooks`. Keep user-persisted settings outside the primary fixture mechanism.
3. Add a direct explicit-false discriminator for the three affected FIFO scenarios. Preserve the production coordinator guard, settings precedence, UI/MCP projections, trust API, queue behavior, and current explicit strict-provider coverage.
4. Verify the future fixture change by running the three exact tests, the complete `CodexFallbackFIFOTests` class, focused coordinator hook-approval tests, MCP strict-mode option/rejection tests, isolated settings persistence tests, and the broader affected test target. Results must be invariant across user-persisted strict-mode values.

## Preventive Measures

- Unit-test fixtures that exercise policy-dependent behavior should own `CodexHookApprovalSettingsProviding` instead of falling back to disk-backed application singletons.
- Non-strict FIFO tests should assert the pre-release gate state and the exact post-release claim/start/attachment or successor transitions under an explicit false provider.
- Strict FIFO coverage should assert that the same review remains pending with zero starts and trust writes, and unchanged queue, in-flight, attachment, blocker, generation, and run-attempt state.

## Accepted GitHub follow-up

Filed as upstream issue 916 on 2026-09-01, titled "Isolate `CodexFallbackFIFOTests` from persisted hook-approval settings", classified as a test-isolation bug, with the proposed labels `bug`, `area:agent-mode`, and `provider:codex`. Its body carries the reproduction, cause, and acceptance criteria from this report.

A duplicate search on 2026-09-01 found no open or closed issue that owned the defect. Closed upstream issue 665 and merged upstream PR 678 own the Codex project-hook approval runtime. Open upstream PR 837 proposes a superseding runtime contract and leaves `CodexFallbackFIFOTests.swift` unchanged. Open upstream PRs 889 and 897 record the same three failures as unrelated validation noise, and neither owns a correction.
