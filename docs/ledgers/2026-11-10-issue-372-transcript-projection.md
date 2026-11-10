# Run ledger: transcript projection streaming conclusions and completed-turn caches

Request: distribution issues #372 and #373 · Plan: `372-373-transcript-projection-2026-11-10.md`

Fix two defects in `AgentTranscriptProjectionBuilder`: a streaming reply that is its turn's conclusion is projected as not streaming (#372), and a completed turn's cached projection is reused after an in-place change to one of its items (#373). Add DEBUG evidence so both fixes and the cache hit rate can be checked in the running debug app.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Keep the source streaming flag on conclusion rows (#372) | done | pair (Claude Code) · Orchestrate 1/3: #372 conclusion streaming flag | `fix(agent-mode): keep the streaming flag on a turn's conclusion row` |
| 2. Validate cached turns against their source turn (#373) | done | pair (Claude Code) · Orchestrate 2/3: #373 completed-turn cache validation | `fix(agent-mode): re-project a completed turn whose items changed in place` |
| 3. DEBUG projection counters and in-place fixture mutation | done | engineer (Codex) · Orchestrate 3/3: DEBUG projection evidence | `feat(diagnostics): count projection cache hits and streaming conclusions` |
| 4. Validate the branch and run the live checks | pending | | |

## 1. Keep the source streaming flag on conclusion rows (#372)

- Decision: `conclusionBlock` builds its row with `activity.toItem()`, so the row keeps the source activity's flag like every other activity-backed row. `conclusionRow(for:)` keeps forcing `false`, because it serves complete turns and a fallback row with no source activity. Source: approved plan.
- Decision: condensed and summary turns also reach `conclusionBlock` through `compactTierBlocks`, so their activity-backed conclusions keep the source flag too. Those turns are complete and the terminal commit barrier finalizes streaming items, so the flag is already `false` there. Source: item agent's observation, accepted.
- Decision: the new suite `Tests/RepoPromptTests/AgentMode/Transcript/AgentTranscriptProjectionBuilderTests.swift` builds fixtures from chat items through `AgentTranscriptIO.buildTranscript` and refreshes grouped-history caches before each build, as the publication path does. Source: approved plan.
- Evidence: `RepoPromptTests.AgentTranscriptProjectionBuilderTests/testConclusionRowKeepsSourceStreamingFlag` failed on the unchanged builder in the two streaming conclusion states (projected `false`, source `true`) and passes with the fix. `AgentTranscriptDebugInstrumentationTests` and `EnhancedMarkdownBareURLTests` pass, and `make dev-format` and `make dev-lint` are clean.
- Evidence: the agent's review and the refactor review each found nothing to change.

## 2. Validate cached turns against their source turn (#373)

- Decision: `AgentTranscriptTurnProjectionCache.ValidationToken` holds the sanitized turn the entry was projected from and the turn's detailed tool-tail allocation. An entry is reused only when both equal the current ones, and the old count-and-ID fields are gone. Synthesized turn equality compares the request, spans and their activities, conclusion ID, tier, summary, and frozen tool-tail limit, so the confirmed in-place mutation paths (assistant text, tool kind, result JSON, error flag, streaming flag) change the token without any caller bumping a counter. The comparison returns early on shared storage. Source: approved plan.
- Decision: a cache hit stores the current turn in the entry, so the next build's comparison ends on Swift's storage-identity fast path and the older equal copy is released. Source: approved plan.
- Decision: one function, `validationToken(for:detailedToolTailLimit:)`, builds every token. Both `projectionCache` overloads take the allocation and call it, so the build loop, the hit check, and `updatedTurnCaches` can't build a token two ways. Source: item agent's judgment, accepted.
- Decision: `testUnchangedCompletedTurnsReuseCachesAcrossTranscriptRebuilds` builds compacted transcripts, departing from the plan's `compact: false` for the test fixtures. Both production imports end in `AgentTranscriptCompactor.compact` (`rebuiltTranscriptPreservingCompactedPrefix`), and compaction clears a full turn's `summary`, so an uncompacted fixture would miss for a reason production never meets. The in-place test keeps `compact: false` on both sides. Source: item agent's judgment, checked against the code.
- Evidence: before the fix, with the #372 fix in place, `testInPlaceChangeToCompletedTurnReprojectsOnlyThatTurn` failed in all four rows (assistant text rewritten, pending tool call finalized, tool result JSON and error flag rewritten, conclusion stops streaming). Each row reported 3 cache hits instead of 2 and still showed the earlier row, so the cached projection differed from an uncached build. `testUnchangedCompletedTurnsReuseCachesAcrossTranscriptRebuilds` passed with 3 hits on both the incremental import and the full rebuild. After the fix all three tests in the suite pass, as do `AgentTranscriptDebugInstrumentationTests` and `EnhancedMarkdownBareURLTests`, and format and lint are clean.
- Evidence: the agent's review and the refactor review each found nothing to change.

## 3. DEBUG projection counters and in-place fixture mutation

- Decision: in DEBUG builds with performance diagnostics enabled, `buildProjection` increments `transcript.projection.build`, `.cacheHit`, `.cacheMiss`, `.sourceStreamingConclusion`, and `.streamingConclusionRow`, and emits a `transcript.projection.build` event whose fields are counts only. The counters are cumulative, so a live check reads them as deltas whatever else runs in the shared debug app. Source: approved plan.
- Decision: all of the counter and event work sits inside the `AgentModePerfDiagnostics.isEnabled` check, so a build with diagnostics off doesn't construct the event's fields. Source: refactor review.
- Decision: `seed_agent_text_derivation_fixture` takes an optional `mutate_completed_conclusion` argument, which rewrites the first turn's conclusion of a seeded two-turn fixture in place through `mutateItem(at:_:)` and refreshes synchronously. It requires `tab_id` (`invalid_params`), and returns `fixture_mismatch` unless the session is inactive and the transcript is that fixture. Source: approved plan.
- Decision: the mutation runs its warm-up refresh before the transcript guards instead of after them. Seeding clears the derived transcript and refreshes asynchronously, so guards that ran first could reject a valid fixture. The run-state guard still runs first, and nothing changes an item before every guard passes. Source: the item agent's review finding, with the reorder by orchestrator judgment.
- Decision: one constant holds the seed's request text, which the seed writes and the mutation guard matches. Source: refactor review.
- Decision: the refactor loop skipped its plan step for this item, because the refactor review named both edits and their locations. Source: orchestrator judgment.
- Evidence: `make dev-swift-build PRODUCT=RepoPrompt`, `AgentTranscriptProjectionBuilderTests`, `AgentTranscriptDebugInstrumentationTests`, `make dev-format`, and `make dev-lint` pass. The agent's review ended with no findings after the reorder. The refactor follow-up found nothing more.

## 4. Validate the branch and run the live checks

- Evidence (live, before): on the integrated debug build without this branch (`dc9cfc1c6`, which includes #378), a Codex-backed session with three short turns streamed a 420-line reply of about 37,000 characters ending in a bare URL. Across the stream, the window's `ui.transcriptRender.window.<id>.bubbleBody` counter grew by 1761 and `markdownCompile` by 1716 (97%), so the reply's markdown compiled on almost every bubble update, the `.immediate` cadence. No `transcript.projection.*` counters exist in that build. The final screenshot showed the trailing URL as a link. No screenshot caught the URL while it was arriving.
- Decision: the live checks use the `engineer` role (Codex) instead of the plan's `explore` role, because the `explore` role's Cursor CLI model answered "Upgrade your plan to continue". Source: orchestrator judgment.
- Decision: the live checks read counter deltas without clearing the performance-diagnostics buffer, which other threads share, and leave diagnostics enabled, because they were enabled before the run. Source: orchestrator judgment.
