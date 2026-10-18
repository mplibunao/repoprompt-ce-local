# Test Coverage Value Audit Ledger — Items 1–5 Final Audit and Acceptance Record

> Investigation report, observed 2026-05-29 to 2026-05-31. It records what was true then. Where it disagrees with a current document, the current document is right.

This report is the ledger upstream committed in `30d8ae319` (2026-05-31) and later deleted in upstream PR 908 (`dbd9eeee6`).

> Single authoritative audit artifact through Item 5. This file records the Item 1 census, merged Item 2 retention/consolidation decisions, merged Item 3 candidate-gap confirmation, the Item 4 exact retention freeze with dependency-safe implementation batches, and the reconciled Item 5 landed deltas, review corrections, recount, and acceptance evidence.

## Scope and status

- Source plan: upstream's audit plan.
- Counted targets: root `RepoPromptTests` from `Tests/RepoPromptTests/**` and nested `RepoPromptClaudeCompatibleProviderTests` from `Packages/RepoPromptAgentProviders/Tests/**`.
- This census owns the count exactly once for each current declared XCTest method whose Swift declaration name begins with `test`.
- **Baseline drift detected:** the plan records `478 root + 5 provider = 483`, but the current clean checkout recount is **`497 root + 5 provider = 502`**. The root target has **19 additional current declarations** relative to the plan baseline. The census below accounts for the current tree rather than silently forcing the stale subtotal.
- No Swift source, Swift test, or script files were edited while creating or merging Items 1–4. Item 5 then landed only the frozen implementation batches, the reviewed minimal production disposition, the uncounted CLI work, and acceptance corrections recorded below.

## Orchestration progress

- [x] Item 1 — Foundational census created and verified against the current checkout. Active audit baseline is **497 root + 5 provider = 502**, with the plan's earlier 483 total retained as historical drift evidence.
- [x] Item 2 — Retention/consolidation review merged and exactly reconciled. Proposed Item 2 allocation is **429 root + 5 provider = 434**, derived from the complete **497 root + 5 provider = 502** current census.
- [x] Item 3 — Candidate-gap confirmation merged and exactly reconciled. Every candidate row has an allowed disposition; approved counted additions are **+16 root + 0 provider**, moving the planning projection from **429 root + 5 provider = 434** to **445 root + 5 provider = 450**. CLI process-harness and live-smoke work is recorded separately as uncounted.
- [x] Item 4 — Retention freeze and dependency-safe batches complete. Frozen allocation is **445 root + 5 provider = 450** counted XCTest methods. The exact VCS-C03 delta is **-1** and the AgentMode provider-cancel protection remains one matrix method.
- [x] Item 5 — Frozen edits landed and reconciled. Final recount is **445 root + 5 provider = 450**; final validation classes are **437 behavioral + 12 structural + 1 diagnostic = 450**. Non-disruptive live smoke was attempted but blocked because the CE app was unavailable; live smoke remains pending a user-approved disruptive launch and is not recorded as passed.

## Baseline and count policy

| Policy | Treatment |
| --- | --- |
| Included unit | Every declaration matching `^\s*func\s+(test[A-Za-z0-9_]*)\s*\(` in first-party Swift test files under the two counted test-target paths. |
| Conditional/opt-in declarations | Counted if declared, including `#if DEBUG` and opt-in benchmark XCTest methods. |
| Hidden breadth | Recorded independently in `scenario_or_fixture_note`; loops, generated loads, tables, resources, and goldens do not multiply declaration count. |
| Excluded | Helper functions not beginning with `test`, live CE MCP smoke, `Vendor/**` tests, scripts, and non-first-party package tests. |
| Exactly-once key | `target + file + declaration line + method name`; the generated manifest asserts uniqueness. |
| Primary counting owner | `primary_contract_id` is deliberately lightweight and suite-scoped for Item 1. Later audit items may refine contract grouping without changing row ownership. |

### Recount evidence

The declaration recount was produced from the current checkout with:

```bash
python3 - <<'PY'
from pathlib import Path
import re
pat = re.compile(r'^\s*func\s+(test[A-Za-z0-9_]*)\s*\(', re.M)
for label, root in [('root', Path('Tests/RepoPromptTests')), ('provider', Path('Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests'))]:
    rows = [(p, m.group(1)) for p in sorted(root.rglob('*.swift')) for m in pat.finditer(p.read_text(errors='replace'))]
    print(f'{label}: {len(rows)}')
PY
```

Current output:

```text
root: 497
provider: 5
total: 502
```

- Canonical current manifest SHA-256 (`target<TAB>file<TAB>line<TAB>method`): `70b3f8f4c1e50c2de05fdda4e7bd65fe0787ccf34a8fa5fedf6c1db3328e6c4e`.
- Repository status observed immediately after recount: clean (`main` → `origin/main`, no changes).

### Historical baseline versus current recount

| Target | Plan baseline | Current declared methods | Drift |
| --- | ---: | ---: | ---: |
| `RepoPromptTests` | 478 | 497 | +19 |
| `RepoPromptClaudeCompatibleProviderTests` | 5 | 5 | +0 |
| **Counted total** | **483** | **502** | **+19** |

### Current root-domain subtotals

| Root domain | Declared methods |
| --- | ---: |
| `AI` | 30 |
| `AgentMode` | 103 |
| `App` | 2 |
| `Chat` | 6 |
| `CodeMap` | 10 |
| `Diagnostics` | 1 |
| `Diffing` | 11 |
| `MCP` | 119 |
| `Prompt` | 22 |
| `Root` | 33 |
| `Security` | 12 |
| `Services` | 54 |
| `WorkspaceContext` | 94 |
| **Root subtotal** | **497** |

### Provisional validation-class totals

> These Item 1 classes are provisional routing labels, not Item 2 retention decisions. Structural and diagnostic rows are intentionally marked for detailed exception review.

| Target | Behavioral coverage | Structural/deletion guard | Diagnostic benchmark | Total |
| --- | ---: | ---: | ---: | ---: |
| `RepoPromptTests` | 478 | 18 | 1 | 497 |
| `RepoPromptClaudeCompatibleProviderTests` | 5 | 0 | 0 | 5 |
| **Counted total** | 483 | 18 | 1 | 502 |

## Item 2 authoritative retention/consolidation merge

### Scope boundary and merge rule

This section merges **Item 2 decisions only** from the four non-overlapping ignored shard reports, which were working files and were not kept. The named shard sections are incorporated by reference as the detailed decision records: they name affected methods, surviving protection, preserved scenarios, rationale, count delta, and later validation lanes. This merge does **not** perform Item 3 candidate-gap confirmation, approve additions, freeze Item 4 batches, or edit Swift files.

| Shard report | Reviewed counting ownership | Current | Proposed retained after Item 2 | Delta |
| --- | --- | ---: | ---: | ---: |
| `test-coverage-value-audit-item2-mcp-report.md` | Root `MCP/**` | 119 | 101 | -18 |
| `test-coverage-value-audit-item2-agent-provider-report.md` | Root `AgentMode/**` + root `AI/**` | 133 | 118 | -15 |
| `test-coverage-value-audit-item2-agent-provider-report.md` | Nested provider-package target | 5 | 5 | 0 |
| `test-coverage-value-audit-item2-workspace-services-report.md` | Root `WorkspaceContext/**` + `Services/**` | 148 | 132 | -16 |
| `test-coverage-value-audit-item2-remaining-domains-report.md` | Remaining root domains and root-level suites | 97 | 78 | -19 |
| **Exact counted reconciliation** | **Root plus provider** | **497 + 5 = 502** | **429 + 5 = 434** | **-68** |

The root ownership rows are non-overlapping and exhaustive: `119 + 133 + 148 + 97 = 497` current root declarations and `101 + 118 + 132 + 78 = 429` proposed retained root declarations. The provider package remains separately owned and unchanged at `5 → 5`. The Item 2 proposal therefore moves the counted suite from `502 → 434` (`-68`) before any Item 3 addition decision.

### Root domain reconciliation

| Root domain | Current census | Proposed retained after Item 2 | Delta | Owning shard |
| --- | ---: | ---: | ---: | --- |
| `AI` | 30 | 21 | -9 | Agent / provider |
| `AgentMode` | 103 | 97 | -6 | Agent / provider |
| `App` | 2 | 2 | 0 | Remaining domains |
| `Chat` | 6 | 1 | -5 | Remaining domains |
| `CodeMap` | 10 | 6 | -4 | Remaining domains |
| `Diagnostics` | 1 | 1 | 0 | Remaining domains |
| `Diffing` | 11 | 8 | -3 | Remaining domains |
| `MCP` | 119 | 101 | -18 | MCP |
| `Prompt` | 22 | 17 | -5 | Remaining domains |
| `Root` | 33 | 32 | -1 | Remaining domains |
| `Security` | 12 | 11 | -1 | Remaining domains |
| `Services` | 54 | 43 | -11 | WorkspaceContext / Services (`FileSystem 12 → 8`; `VCS 42 → 35`) |
| `WorkspaceContext` | 94 | 89 | -5 | WorkspaceContext / Services |
| **Root subtotal** | **497** | **429** | **-68** | **Exact** |
| Nested provider package | 5 | 5 | 0 | Agent / provider |
| **Counted total** | **502** | **434** | **-68** | **Exact** |

### Validation-class totals and threshold-trigger rationale status

| Validation class | Current counted methods | Proposed retained after Item 2 | Delta | Threshold-trigger status |
| --- | ---: | ---: | ---: | --- |
| Behavioral coverage | 483 | 421 | -62 | Primary retained allocation; no numeric review trigger. |
| Structural/deletion guard | 18 | 12 | -6 | **Triggered** because proposed allocation is above 10. Rationale is satisfied for Item 2 by the explicit 12-method exception inventory below; recheck at the later retention freeze if Item 3 or implementation changes the allocation. |
| Diagnostic benchmark | 1 | 1 | 0 | Not triggered: proposed allocation is not above 2. |
| **Counted total** | **502** | **434** | **-68** | Exact. |

| Shard class allocation | Current behavioral | Current structural | Current diagnostic | Proposed behavioral | Proposed structural | Proposed diagnostic | Proposed total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| MCP | 114 | 5 | 0 | 97 | 4 | 0 | 101 |
| AgentMode / AI / provider | 132 | 5 | 1 | 118 | 4 | 1 | 123 |
| WorkspaceContext / Services | 145 | 3 | 0 | 129 | 3 | 0 | 132 |
| Remaining domains | 92 | 5 | 0 | 77 | 1 | 0 | 78 |
| **Exact counted reconciliation** | **483** | **18** | **1** | **421** | **12** | **1** | **434** |

Root contributes `416 behavioral + 12 structural + 1 diagnostic = 429`; the nested provider package contributes `5 behavioral`. The structural review trigger is not a pre-approved cap. The retained `12` methods are accepted for Item 2 because each protects an architecture/removal, copied exposure, DEBUG observability, concurrency-safety, or ownership boundary that is not cheaply replaced by existing behavioral assertions.

### Proposed consolidation/deletion decision index

Every Item 2 reduction below is covered by a linked detailed shard record. Scenario-preserving consolidations must carry their listed rows into the surviving declaration. Transfers or decompositions marked atomic must land with their surviving protection; no deletion-first implementation is authorized.

#### MCP shard — `119 → 101` (`-18`)

Detailed records: `test-coverage-value-audit-item2-mcp-report.md` § “Detailed consolidation and deletion decisions”.

| Decision | Purpose | Delta |
| --- | --- | ---: |
| `MCP-CONS-01` | Combine connection-manager source safety guards. | -1 structural |
| `MCP-CONS-02` | Merge bound/unbound effective workspace-path checks. | -1 |
| `MCP-CONS-03` | Merge direct child-binding inheritance opt-in/opt-out checks. | -1 |
| `MCP-CONS-04` | Consolidate MCP parent-source inheritance combinations. | -3 |
| `MCP-CONS-05` | Merge explicit-worktree precedence cases. | -1 |
| `MCP-CONS-06` | Merge resolver explicit-ID and legacy-alias success paths. | -1 |
| `MCP-CONS-07` | Merge runless binding-release preserve/drop branches. | -1 |
| `MCP-CONS-08` | Merge nested-source rejection and top-level allowance checks. | -1 |
| `MCP-CONS-09` | Combine `manage_worktree` capability and routing-policy footprint. | -1 |
| `MCP-CONS-10` | Remove duplicate catalog-order declaration and transfer unique alias-removal checks. | -1 |
| `MCP-CONS-11` | Remove exact merge-schema subset duplication. | -1 |
| `MCP-CONS-12` | Remove redundant merge DTO nesting fixture; retain stronger service/formatter protection. | -1 |
| `MCP-CONS-13` | Transfer previous-binding formatter coverage to formatter ownership. | -1 |
| `MCP-CONS-14` | Consolidate discovery-tool worktree-scope formatters. | -2 |
| `MCP-CONS-15` | Move list formatting coverage to formatter ownership without reducing declarations. | 0 |
| `MCP-CONS-16` | Consolidate available/unavailable `agent_run` formatter coverage. | -1 |
| **MCP subtotal** |  | **-18** |

#### AgentMode / AI / provider shard — `138 → 123` (`-15`)

Detailed records: `test-coverage-value-audit-item2-agent-provider-report.md` § “Proposed scenario-preserving consolidations”. The linked report also records two rejected quota-chasing collapses (`R1`, `R2`) that remain retained.

| Decision | Purpose | Delta |
| --- | --- | ---: |
| `C1` | Recommendation-provider normalization matrix. | -2 |
| `C2` | Sidebar root-row default worktree projection. | -1 |
| `C3` | Worktree merge-card nil-DTO fallback matrix. | -1 |
| `C4` | Transcript Oracle tool-name allow-list boundary. | -1 |
| `C5` | Transcript activation-remount suppression matrix. | -1 |
| `C6` | Oracle-planning dropdown invalid-state matrix. | -1 |
| `C7` | Consolidate `PromptViewModel` strict-planning source guard. | -1 structural |
| `C8` | AI Queries Codex ephemeral-thread policy matrix. | -2 |
| `C9` | Codex CLI provider-forwarding matrix. | -1 |
| `C10` | Codex active-turn mismatch parser matrix. | -1 |
| `C11` | Codex interrupt-turn resolution matrix. | -1 |
| `C12` | Codex fresh `thread/start` JSON-RPC shape matrix. | -2 |
| `C13` | Optional assertion-level cleanup inside prompt-export persistence coverage. | 0 |
| **AgentMode / AI / provider subtotal** | Provider package remains `5 → 5`. | **-15** |

#### WorkspaceContext / Services shard — `148 → 132` (`-16`)

Detailed records: `test-coverage-value-audit-item2-workspace-services-report.md` § “Detailed consolidation decisions”.

| Decision | Purpose | Delta |
| --- | --- | ---: |
| `WS-STORE-C01` | Consolidate batch root-unload scenarios. | -1 |
| `WS-STORE-C02` | Consolidate successful `mode: "slices"` set scenarios. | -1 |
| `WS-STORE-C03` | Consolidate `mode: "slices"` rejection scenarios. | -1 |
| `WS-STORE-C04` | Consolidate loaded root-shell integration scenarios. | -1 |
| `WS-SEL-C01` | Consolidate save-snapshot stored-selection fallback variants. | -1 |
| `FS-C01` | Consolidate routine event-path mapping cases. | -4 |
| `VCS-C01` | Consolidate supported repository-selector syntax. | -5 |
| `VCS-C02` | Consolidate malformed porcelain-input rejection cases. | -1 |
| `VCS-C03` | Atomically decompose bundled preview/dirty/stale real-worktree declaration into existing focused owners. | -1 proposed; reconcile later actual delta if a new declaration is required |
| **WorkspaceContext / Services subtotal** |  | **-16 proposed** |

#### Remaining domains shard — `97 → 78` (`-19`)

Detailed records: `test-coverage-value-audit-item2-remaining-domains-report.md` § “Detailed deletion and consolidation decisions”.

| Decision | Purpose | Delta |
| --- | --- | ---: |
| `REM-CODEMAP-01` | Consolidate three golden-loop declarations while preserving all 13 fixture/golden rows. | -2 |
| `REM-CODEMAP-02` | Consolidate compact auto-mode tree smoke into full-tree snapshot owner. | -1 |
| `REM-CODEMAP-03` | Fold initial mismatched-CodeMap rejection into accepted-state lifecycle owner. | -1 |
| `REM-CODEMAP-04` | Preserve per-group fixture caps inside consolidated golden owner. | 0 |
| `REM-CHAT-01` | Consolidate chat-name extraction scenarios into one labeled table. | -5 |
| `REM-DIFF-01` | Consolidate insertion/deletion cumulative-offset variants. | -1 |
| `REM-DIFF-02` | Consolidate text-preservation and no-op rows. | -2 |
| `REM-PROMPT-01` | Consolidate resolved file-tree truth table. | -2 |
| `REM-PROMPT-02` | Delete obsolete `PromptViewModel` source-spelling migration guard. | -1 |
| `REM-PROMPT-03` | Consolidate and retain bundled prompt-mirror structural exception. | -2 structural |
| `REM-SECURITY-01` | Delete removed-Gemini reset inertness assertion as not a current CE contract. | -1 |
| `REM-ROOT-01` | Delete obsolete legacy-workspace-aggregator source-spelling guard. | -1 |
| **Remaining-domains subtotal** |  | **-19** |

### Retained structural/deletion-guard exception inventory — 12 methods

The repository-wide structural threshold review is triggered (`12 > 10`) and satisfied for Item 2 by these explicit exceptions. Detailed affected-method names, preserved assertions, and rationales are incorporated from the linked sections.

| Owning shard | Exception records | Proposed methods | Why behavioral coverage alone is insufficient |
| --- | --- | ---: | --- |
| MCP | `MCP-STRUCT-01`, `MCP-STRUCT-02`, `MCP-STRUCT-03`, `MCP-STRUCT-04` in `test-coverage-value-audit-item2-mcp-report.md` | 4 | Preserve removed unsafe/incomplete connection-manager paths, copied stale CE command exposure scans, `manage_worktree` parser/group/help exposure, and legacy workflow namespace removal. The CLI exposure guard remains structural and does not claim executable parser/forwarding coverage. |
| AgentMode / AI | `S1`, `S2`, `S3`, `S4` in `test-coverage-value-audit-item2-agent-provider-report.md` | 4 | Preserve the single allowed provider-package importer, strict Oracle reporting wiring, the combined `PromptViewModel` strict-planning guard, and removed legacy MCP planning-model migration paths. These are narrow architecture/wiring/removal boundaries. |
| WorkspaceContext / Services | `WS-STRUCT-01`, `WS-STRUCT-02`, `WS-STORE-STRUCT-01` in `test-coverage-value-audit-item2-workspace-services-report.md` | 3 | Preserve runtime-search cutover deletion, DEBUG store-backed loading diagnostics layering, and deferred initial scan-flush ownership without weaker timing-dependent black-box proxies. |
| Remaining domains | `REM-PROMPT-03` in `test-coverage-value-audit-item2-remaining-domains-report.md` | 1 | Preserve absence of the removed bundled prompt mirror, presence of canonical compiled prompt sources, and absence of stale mirror-path references. |
| **Structural subtotal** |  | **12** | **Threshold rationale recorded. Re-evaluate at Item 4 retention freeze.** |

Embedded CodeMap bounded-fixture caps from `REM-CODEMAP-04` remain assertions inside the retained behavioral golden owner; they are not additional structural XCTest declarations.

### Retained diagnostic benchmark exception inventory — 1 method

| Owning shard | Exception record | Proposed methods | Rationale |
| --- | --- | ---: | --- |
| AgentMode transcript | `D1 — Opt-in transcript crawl-refresh benchmark` in `test-coverage-value-audit-item2-agent-provider-report.md` | 1 | Retain the DEBUG/opt-in report harness separately from behavioral transcript protection. It measures long active-crawl final-turn refresh and is explicitly tracked rather than misclassified. |
| **Diagnostic subtotal** |  | **1** | **No threshold rationale required (`1 ≤ 2`).** |

`Diagnostics/BenchmarkDiffApplierTests.testModifyChangeAppliesGeneratedDiffChunks`, DEBUG replay-evidence coverage, ignore metrics coverage, and store scan-targeting tests remain behavioral because they assert deterministic pass/fail outcomes rather than only emit measurements.

### Cross-layer ownership decisions retained

The following named sections are part of the authoritative Item 2 record. Similar identifiers or fixtures do not authorize collapsing distinct package/root, unit/integration, serialization/presentation, catalog/consumer, persistence/reconciliation/UI, or primitive/orchestration layers.

| Shard | Incorporated ownership decision records | Required boundary |
| --- | --- | --- |
| MCP | `Retained cross-layer overlap decisions` in `test-coverage-value-audit-item2-mcp-report.md` | Retain the report's catalog golden versus readable-field assertions, registration ownership, DTO coding keys, graph metadata, merge formatter versus smoke, single scope-block composition, direct inheritance versus MCP integration, snapshot serialization versus formatter rendering, pure policy versus integration, DEBUG routing validation, wait-any async/payload split, MCP control notifications, and real temporary-Git smoke layers. |
| AgentMode / AI / provider | `O1`, `O2`, `O3`, `O4`, `O5`, `O6`, `O7`, `O8`, `O9`, `O10` in `test-coverage-value-audit-item2-agent-provider-report.md` | Retain provider-package pure runtime/catalog/codec behavior separately from root bridge, catalog conversion, and permission policy; preserve Codex policy verticals, transcript persistence/projection/benchmark traversal, ask-user model versus Context Builder integration, worktree persistence/reconciliation/review/UI, semantic model-order projections, and UI-race versus detached-cleanup layers. |
| WorkspaceContext / Services | `Retained cross-layer overlap decisions` in `test-coverage-value-audit-item2-workspace-services-report.md` | Retain compiler versus service ignore precedence, low-level versus VCS clean merge, conflict primitive versus persisted reconciliation, both advisory-lock layers, and all five root-binding projection declarations. |
| Remaining domains | `Ownership-layer and cross-shard boundaries` in `test-coverage-value-audit-item2-remaining-domains-report.md` | Retain App router parsing, Diagnostics integration, the mixed-owner DiffParser declaration, Prompt/store handoff, workflow catalog rendering, Security fail-closed policy, root persistence/UI policy, and CodeMap syntax/tree contracts without collapsing consumer layers. |

### CodeMap fixture/golden breadth retained

The CodeMap consolidation is declaration-count reduction, not fixture reduction. `REM-CODEMAP-01` preserves all **13** explicit fixture/golden comparisons: `5` CE/core, `5` expanded-language, and `3` edge fixtures. `REM-CODEMAP-02` preserves explicit full rendering plus compact auto-mode dispatch against the same tree golden. `REM-CODEMAP-04` preserves group caps of `≤5`, `≤5`, and `≤3` in the consolidated owner. Added unlisted or orphan fixtures/goldens remain an Item 2 observation only; this merge does not perform Item 3 confirmation or approve a new inventory guard.

### Item 2 completion and deferred issues

- **Item 2 is complete:** shard ownership is exhaustive and non-overlapping; current and proposed arithmetic reconcile exactly to `497 root + 5 provider = 502` and `429 root + 5 provider = 434`.
- **No Item 2 issue blocks Item 3 gap analysis.** Candidate-gap confirmation remains intentionally unperformed. In particular, executable CLI parser/forwarding accessibility, `PartitionStore` / `SliceRebaseEngine`, diff generation, secure storage, window-close policy, and agent-run lifecycle questions remain deferred to Item 3 without addition approval.
- `VCS-C03` has an implementation-time conditional delta: its proposed `-1` assumes all scenarios fold into existing focused declarations. If implementation requires a new XCTest declaration, Item 4 batch planning must reconcile the actual delta instead of forcing `-1`. This does not block Item 3 gap analysis.
- CodeMap fixture↔golden exact-inventory coverage is an observation, not an approved addition and not a blocker.
- No Swift source or test files were edited and no test command was run during the Item 2 documentation merge.

## Item 3 authoritative candidate-gap confirmation merge

### Scope boundary and merge rule

This section merges **Item 3 candidate-gap confirmation only** from the four non-overlapping ignored reports, which were also working files and were not kept. The named reports are incorporated by reference as the detailed evidence records. This merge resolves each apparent-gap row to an allowed disposition, records approved scenarios, target ownership, count delta, validation lane, and any minimal deterministic seam. It does **not** perform Item 4 retention freeze or batch planning, edit Swift or scripts, run validation lanes, or touch unrelated tracked administration work.

| Item 3 report | Reviewed candidate ownership | Counted root delta | Provider delta | Uncounted harness / live work |
| --- | --- | ---: | ---: | --- |
| `test-coverage-value-audit-item3-diff-report.md` | Root Diffing and MCP ApplyEdits behavior | +2 | 0 | None |
| `test-coverage-value-audit-item3-security-app-report.md` | Root Security and App close policy | +6 | 0 | None |
| `test-coverage-value-audit-item3-slices-report.md` | Root WorkspaceContext slice persistence / rebase | +3 | 0 | None |
| `test-coverage-value-audit-item3-agent-cli-report.md` | Root AgentMode lifecycle and CE MCP CLI executable boundary | +5 | 0 | Deterministic CLI process harness plus targeted live smoke |
| **Approved Item 3 total** | **All protocol candidates resolved** | **+16** | **0** | **CLI work remains uncounted** |

### Exact post-Item-3 planning projection

| Reconciliation step | Root `RepoPromptTests` | Nested provider target | Counted total |
| --- | ---: | ---: | ---: |
| Current Item 1 census | 497 | 5 | 502 |
| Item 2 proposed retention/consolidation delta | -68 | 0 | -68 |
| Post-Item-2 proposal | 429 | 5 | 434 |
| Item 3 approved counted additions | +16 | 0 | +16 |
| **Post-Item-3 planning projection** | **445** | **5** | **450** |

The arithmetic is exact: `429 + 16 = 445` root and `445 + 5 = 450` counted total. This remains below the provisional `500`-method ceiling. The AgentMode report notes that Item 4 could deliberately split the provider-cancel matrix into one extra declaration (`+6` rather than `+5` for that report), but that optional split is **not approved or counted by this Item 3 merge**. If Item 4 chooses it, Item 4 must explicitly reconcile the revised projection (`446 root + 5 provider = 451`) instead of silently changing this exact Item 3 projection.

### DiffGenerationUtility routing, search-block ambiguity, and failure

Overall protocol-row disposition: **`uncovered-current-contract — focused addition approved`**. Existing outcome-level integration protects active success routing, but unmatched, exact ambiguity semantics, and the `replaceAll` duplicate-match bypass remain insufficiently protected. Full evidence: `test-coverage-value-audit-item3-diff-report.md`.

| Candidate row | Allowed disposition | Direct / indirect evidence | Approved scenarios | Target and counted delta | Validation lane | Minimal seam |
| --- | --- | --- | --- | --- | --- | --- |
| Active `.rewrite` routing without search block | `covered-indirectly — no addition` | `DiffGenerationUtility.swift:108-113`; active MCP route at `ApplyEditsEngine.swift:24-44,512-527`; `ApplyEditsCoreRecoveryTests.swift:9-27` asserts rewritten text and verbose diff. | Retain existing façade rewrite protection. | Existing root MCP coverage; `+0`. | Existing ApplyEdits focused lane when touched. | None. |
| Active `.modify` routing with search block | `covered-indirectly — no addition` | `DiffGenerationUtility.swift:98-111`; `DiffBatchGenerator.swift:61-79`; `ApplyEditsCoreRecoveryTests.swift:68-88`; distinct Diagnostics integration in `BenchmarkDiffApplierTests.swift:5-59`. | Retain current modify/search-block success layers. | Existing root MCP / Diagnostics coverage; `+0`. | Existing touched-suite lanes. | None. |
| `.create` / `.delete` branches on the façade | `not-current-contract — no addition` | Branches exist at `DiffGenerationUtility.swift:87-91`, but current façade callers do not pass those actions; shipped create/delete behavior uses other paths. | None. Do not add tests merely for unused façade branches. | No test target; `+0`. | None. | None. |
| Legacy selector-only façade input | `not-current-contract — no addition` | `DiffGenerationUtility.swift:112-138` immediately throws and retains only commented legacy logic; current callers pass nil selectors. | None. | No test target; `+0`. | None. | None. |
| Unmatched current search-block selection | `uncovered-current-contract — focused addition approved` | Active helper failure at `DiffGenerationUtility.swift:400-406`, batch projection at `DiffBatchGenerator.swift:81-88`, and single MCP translation at `ApplyEditsEngine.swift:528-535`; inspected tests do not assert either observable unmatched outcome. | Add one combined ApplyEdits method: assert exact single-edit invalid-params error and batch `.failed` outcome, unchanged text, zero applied edits, and localized exact failure message. | Root `RepoPromptTests`, extend `MCP/ApplyEdits/ApplyEditsCoreRecoveryTests.swift`; `+1`. | `make dev-test FILTER=ApplyEditsCoreRecoveryTests` | None. |
| Ambiguous current search-block selection | `uncovered-current-contract — focused addition approved` | `DiffGenerationUtility.swift:1532-1541` emits semantic line-number error. Existing `ApplyEditsCoreRecoveryTests.swift:91-113` reaches it but asserts only non-nil error text. | Strengthen existing partial-outcome method to assert the exact ambiguity message while preserving later partial success. | Root `RepoPromptTests`; `+0`. | `make dev-test FILTER=ApplyEditsCoreRecoveryTests` | None. |
| `replaceAll` duplicate-match ambiguity bypass | `uncovered-current-contract — focused addition approved` | `DiffGenerationUtility.swift:312-385` has repeated-match and cumulative-offset handling. Existing tests parse `replaceAll` but do not execute this branch. | Add one direct façade contrast method with duplicate matches, ambiguity check enabled, `replaceAll: true`, line-count-changing replacement, chunk application, and all-occurrence assertions. | Root `RepoPromptTests`, new `Diffing/DiffGenerationUtilityRoutingTests.swift`; `+1`. | `make dev-test FILTER=DiffGenerationUtilityRoutingTests` | None; internal façade and chunk applier are already reachable with `@testable import RepoPrompt`. |

### DEBUG secure-storage persistence policy and successful secure write

Overall protocol-row disposition: **`uncovered-current-contract — focused addition approved`**. Full evidence: `test-coverage-value-audit-item3-security-app-report.md`.

| Candidate row | Allowed disposition | Direct / indirect evidence | Approved scenarios | Target and counted delta | Validation lane | Minimal seam |
| --- | --- | --- | --- | --- | --- | --- |
| DEBUG backend-selection policy and successful Keychain write path | `uncovered-current-contract — focused addition approved` | `KeychainServiceTests.swift:7-77` covers read/delete only. Repository test search found no `SecureKeyValueStorageFactory`, `DebugSecureStorageRuntimePolicy`, `RuntimeCodeSigningInfo`, or ephemeral-backend reference. `AgentPermissionSecureStoreTests.swift:14-190` injects a fake and therefore does not reach selection policy or `KeychainService.save`. | Add one DEBUG policy truth-table method for explicit normalized `keychain` marker plus non-empty TeamIdentifier; add two `KeychainService.save` methods for update-success/no-add and update-missing/add-success canonical CE attributes and UTF-8 payload. | Root `RepoPromptTests`: new `Security/DebugSecureStorageRuntimePolicyTests.swift` `+1`; extend `Security/KeychainServiceTests.swift` `+2`; total `+3`. | `make dev-test FILTER=DebugSecureStorageRuntimePolicyTests`; `make dev-test FILTER=KeychainServiceTests` | None. Existing pure `DebugSecureStorageRuntimePolicy.backendKind` and injected `SecItemClient` are sufficient. A test-only query helper is allowed if needed. |

### WindowCloseCoordinator.decide

Overall protocol-row disposition: **`uncovered-current-contract — focused addition approved`**. Full evidence: `test-coverage-value-audit-item3-security-app-report.md`.

| Candidate row | Allowed disposition | Direct / indirect evidence | Approved scenarios | Target and counted delta | Validation lane | Minimal seam |
| --- | --- | --- | --- | --- | --- | --- |
| Pure app-close decision ordering and messaging | `uncovered-current-contract — focused addition approved` | Repository test search found no `WindowCloseCoordinator`, close-decision/snapshot types, or close-confirmation strings. Existing `AppPlatformUtilityRecoveryTests.swift:1-57` protects unrelated deep-link and appcast parsing. | Add three table-oriented methods: termination/authorization precedence; active-work precedence plus deterministic formatting; MCP continuity confirmations plus ordinary allow cases. Do not add presentation-only `.background` or `.denyDuplicatePrompt` cases to this pure seam. | Root `RepoPromptTests`, new `App/WindowCloseCoordinatorDecisionTests.swift`; `+3`. | `make dev-test FILTER=WindowCloseCoordinatorDecisionTests` | None; internal static `decide(snapshot:authorization:)` is already pure and reachable. |

### PartitionStore / SliceRebaseEngine

Overall protocol-row disposition: **`uncovered-current-contract — focused addition approved`**. Retain the existing observable deletion-reconciliation integration while adding the three missing direct outcomes. Full evidence: `test-coverage-value-audit-item3-slices-report.md`.

| Candidate row | Allowed disposition | Direct / indirect evidence | Approved scenarios | Target and counted delta | Validation lane | Minimal seam |
| --- | --- | --- | --- | --- | --- | --- |
| Existing partition-backed write/load/delete reconciliation | `covered-indirectly — no addition` | `WorkspaceFileContextStoreTests.testHydrateSlicesForActiveTabWithEmptyStoredSelectionDeletesPersistedSlices` creates visible state, hydrates empty active-tab selection, then proves visible and partition-backed absence through the production view-model/store path. | Retain existing integration method. | Existing root WorkspaceContext coverage; `+0`. | Existing touched-suite lane. | None. |
| Positive cold partition durability plus scope isolation | `uncovered-current-contract — focused addition approved` | Existing hydration coverage stays in one coordinator lifetime and proves absence after deletion; it does not cold-reload exact persisted ranges, anchors, metadata, or tab/workspace partition isolation. | Add one method using a temporary partition base: writer persists normalized ranges, metadata, and anchors; fresh reader round-trips exact value; another tab scope is empty, with alternate-workspace assertion optionally in the same method. | Root `RepoPromptTests`, focused WorkspaceContext slice suite; `+1`. | `make dev-test FILTER=SelectionSlicePersistenceAndRebaseTests`; if seam lands, `make dev-swift-build PRODUCT=RepoPrompt`. | Allow one narrow behavior-preserving `PartitionStore` base-directory initializer dependency defaulting to the existing Application Support location. |
| Dropped-range rebase outcomes | `uncovered-current-contract — focused addition approved` | No test references `SliceRebaseEngine`; existing slice integrations do not mutate sliced content or assert a rebase result. Engine drops ranges for empty new content and unresolved anchor mappings. | Add one table-driven pure-engine method: empty new content and unmappable selected signature both yield `rebased == []`, original dropped range, and `didChange == true`. | Root `RepoPromptTests`, focused WorkspaceContext slice suite; `+1`. | `make dev-test FILTER=SelectionSlicePersistenceAndRebaseTests` | None. |
| Equal-cache anchor-fallback regression (`oldText == newText`) | `uncovered-current-contract — focused addition approved` | `SliceRebaseEngine.swift:37-65` explicitly guards the cache edge; no observable WorkspaceContext or direct engine test protects it. | Add one pure-engine method with stale range and saved pre-edit anchor, current content supplied as both old and new, and a unique inserted line above selection; assert shifted range, no drops, and change. | Root `RepoPromptTests`, focused WorkspaceContext slice suite; `+1`. | `make dev-test FILTER=SelectionSlicePersistenceAndRebaseTests` | None. |

Recorded residual limitation, not an approved addition and not a freeze blocker: the three methods do not claim full asynchronous `WorkspaceFilesViewModel` modified-file orchestration coverage. Expand only if Item 4 explicitly broadens ownership beyond the cited store/engine seam.

### AgentModeRunService provider/run lifecycle

Overall protocol-row disposition: **`uncovered-current-contract — focused addition approved`**. Existing adjacent outcomes remain retained where sufficient; add a focused five-method lifecycle matrix without duplicating them. Full evidence: `test-coverage-value-audit-item3-agent-cli-report.md`.

| Candidate row | Allowed disposition | Direct / indirect evidence | Approved scenarios | Target and counted delta | Validation lane | Minimal seam |
| --- | --- | --- | --- | --- | --- | --- |
| Pre-provider startup-failure transition | `uncovered-current-contract — focused addition approved` | `AgentRunWorktreeStartTests.swift:26-46` asserts the pure missing-worktree recovery text through `effectiveWorkspacePath`, but does not execute `startAgentRun` or `failBeforeProviderStartup` at `AgentModeRunService.swift:143-149,444-474`. | Add one missing-worktree method asserting failed state/outcome, one recovery error item, inactive binding, and no provider/controller factory invocation. | Root `RepoPromptTests`, focused `AgentModeRunServiceLifecycleTests.swift`; `+1`. | Lifecycle focused lane plus adjacent lanes listed below. | Existing DEBUG initializer injections. |
| Current provider dispatch matrix | `uncovered-current-contract — focused addition approved` | No direct root `AgentModeRunService` test. Current explicit Codex, Claude-native, and ACP routes are at `AgentModeRunService.swift:152-218`. | Add one matrix method using recorders/fakes for `.codexExec`, a Claude-native provider, and an ACP provider; assert only expected runner/factory family is entered. | Root `RepoPromptTests`, focused lifecycle suite; `+1`. | Lifecycle focused lane plus adjacent lanes listed below. | Existing DEBUG initializer injections. |
| Final headless fallback for a future provider | `not-current-contract — no addition` | Every current provider kind is Codex, Claude-native, or ACP-routed; the fallback at `AgentModeRunService.swift:220-227` has no current selecting provider. | None until a future provider selects it. | No test target; `+0`. | None. | None. |
| Claude queued steering drain and failed-send restoration | `uncovered-current-contract — focused addition approved` | MCP wait-output coverage asserts wake serialization shape but does not execute Claude idle gate, native send, queue drain, or failed-send restoration at `AgentModeRunService.swift:669-830`. | Add one matrix method: success waits idle before send and drains queue; failed send restores draft and clears queue. | Root `RepoPromptTests`, focused lifecycle suite; `+1`. | Lifecycle focused lane plus adjacent lanes listed below. | Approve only if required: optional DEBUG-only MCP-idle waiter override wired to `AgentModeRunService.Dependencies.awaitNoActiveMCPTools`, retaining shipped default behavior. |
| ACP queued steering ordering | `uncovered-current-contract — focused addition approved` | ACP identity tests exercise controller bootstrap/load identity, not service queue drain, idle ordering, interrupt/prompt send, or restoration at `AgentModeRunService.swift:288-442`. | Add one ACP method asserting idle wait before interrupt/prompt send and queue drain or deterministic restoration on failed send. | Root `RepoPromptTests`, focused lifecycle suite; `+1`. | Lifecycle focused lane plus adjacent lanes listed below. | Same optional DEBUG-only MCP-idle waiter override only if required. |
| Guarded common user-stop cancellation | `covered-indirectly — no addition` | `AgentModeStopSubmitTargetTests.swift:35-92` already verifies target routing, MCP run cancellation observation, cancelled state, and stale-target refusal through `cancelAgentRun`. | Retain existing common-cancel protection; do not duplicate. | Existing root AgentMode coverage; `+0`. | `make dev-test FILTER=AgentModeStopSubmitTargetTests` when implementation touches lifecycle cancel wiring. | None. |
| Execution-location-change draft restoration | `covered-indirectly — no addition` | `AgentRunWorktreeStartTests.swift:627-688` verifies confirmation, old binding before confirmation, queued ACP/shared-draft restoration, identity invalidation, and no in-flight-prompt replay. | Retain existing integration protection; do not duplicate. | Existing root MCP coverage; `+0`. | `make dev-test FILTER=AgentRunWorktreeStartTests` when implementation touches shared behavior. | None. |
| Current provider-specific cancel cleanup matrix | `uncovered-current-contract — focused addition approved` | Existing common-cancel protection does not assert Claude-native and ACP controller cleanup branches at `AgentModeRunService.swift:990-1044`. | Add one matrix method for Claude-native and ACP-controller cancel: common MCP-tool cancellation precedes shutdown, runtime/controller reference clears, fake cleanup is reached. Codex common cancel remains indirect unless implementation proves a missing Codex-specific assertion. | Root `RepoPromptTests`, focused lifecycle suite; `+1`. | Lifecycle focused lane plus adjacent lanes listed below. | Existing DEBUG initializer injections. |

AgentMode later-implementation validation lanes:

```bash
make dev-test FILTER=AgentModeRunServiceLifecycleTests
make dev-test FILTER=AgentModeStopSubmitTargetTests
make dev-test FILTER=AgentRunWorktreeStartTests
make dev-swift-build PRODUCT=RepoPrompt
```

Because the later implementation affects Agent Mode runtime behavior, record applicable CE live MCP smoke separately. Use credentialed `./conductor smoke --agent-run` only when provider credentials and model access are intentionally available.

### Executable CE MCP CLI parsing and forwarding — uncounted process and live lanes

Accessibility decision: the existing root XCTest target cannot directly import the separate `RepoPromptMCP` executable without dependency or production-design changes, but an executable/process harness can reach the boundary without either change. Full evidence: `test-coverage-value-audit-item3-agent-cli-report.md`.

| Candidate row | Allowed disposition | Direct / indirect evidence | Approved scenarios | Harness / live target and count treatment | Validation lane | Minimal seam |
| --- | --- | --- | --- | --- | --- | --- |
| Deterministic executable parser behavior for direct `manage_worktree` syntax | `uncovered-current-contract — focused addition approved` | Structural `CECLINamingAndRoutingTests.swift:75-108` reads parser/group/help source strings but does not execute `MCPCommandParser`. The DEBUG executable already exposes real-parser `--test-parse` at `Sources/RepoPromptMCP/main.swift:1715-1725,2366-2445`. | Add a narrow process harness for key/value shorthand (`aliasCall`, converted args) and JSON payload (`call`, preserved payload) using the coordinated debug executable artifact. | Executable/process harness against coordinated debug `repoprompt-mcp`; **uncounted:** `+0` XCTest methods. | `make dev-swift-build PRODUCT=repoprompt-mcp`; run narrow executable `--test-parse` harness. | None; reuse existing DEBUG `--test-parse` hook. |
| General live executable forwarding | `covered-indirectly — retain live smoke` | Existing conductor smoke invokes CLI process for `windows`, `workspace switch`, `tree --type roots`, and direct `agent_manage`, covering launch, bootstrap connection, and representative forwarding. | Retain existing live smoke stages. | CE debug CLI live smoke; **uncounted live smoke.** | `make dev-smoke`, or `make dev-smoke-launch` when intentional launch is required. | None. |
| Live `manage_worktree` parser-to-forwarding vertical | `uncovered-but-live-only — smoke lane recorded` | Existing live smoke does not issue shorthand `manage_worktree`; app-internal worktree harnesses bypass the executable parser. | Add targeted smoke stage: `rpce-cli-debug -w 1 -e 'manage_worktree op=list'`. | CE debug CLI live smoke; **uncounted live smoke.** | `make dev-smoke`, or `make dev-smoke-launch` when intentional launch is required. | None. |

No `RepoPromptTests` target-dependency change, CLI production redesign, or new production seam is approved. CLI process-harness and live-smoke work must remain separate from the counted `445 root + 5 provider = 450` projection.

### Item 3 completion and Item 4 handoff

- **Item 3 is complete:** every candidate row is resolved to one allowed disposition and the counted arithmetic reconciles exactly to **`445 root + 5 provider = 450`** after all approved counted additions.
- **Item 4 has not been performed.** The projection above is not a retained-subtotal freeze and does not authorize implementation batches.
- The deterministic CLI `--test-parse` process harness and targeted `manage_worktree op=list` live smoke are approved but uncounted. They do not change the XCTest projection.
- No unresolved Item 3 candidate decision blocks Item 4. Before freezing batches, Item 4 must explicitly reconcile the already-recorded `VCS-C03` implementation-time conditional delta and decide whether to keep the approved one-method AgentMode provider-cancel matrix or deliberately split it into an extra declaration. The optional split is not required by Item 3 and is not included in the `450` projection.
- The slices report's asynchronous view-model orchestration limitation and the Item 2 CodeMap fixture↔golden exact-inventory observation are recorded residuals, not approved additions and not freeze blockers unless Item 4 deliberately expands scope.
- No Swift source, Swift test, or script file was edited and no validation lane was run during this Item 3 documentation merge.

## Item 4 authoritative retention freeze and dependency-safe implementation batches

### Scope boundary and freeze rule

This section performs **Item 4 only**. It freezes exact retained subtotals, validation-class totals, threshold rationale, the two explicit implementation choices handed off by Item 3, and a small dependency-safe sequence for later Item 5 implementation. It does **not** edit Swift files, scripts, `Makefile`, or unrelated administration files, and it does not run validation lanes.

All later implementation work must follow the frozen records below. Replacement protection lands first or atomically with any dependent declaration removal. If implementation discovers a materially different contract or an unavoidable extra declaration, stop and revise this authoritative freeze before continuing rather than silently drifting from the reconciled allocation.

### Exact counted allocation freeze

| Reconciliation step | Root `RepoPromptTests` | Nested provider target | Counted total |
| --- | ---: | ---: | ---: |
| Current Item 1 census | 497 | 5 | 502 |
| Frozen Item 2 consolidations/removals | -68 | 0 | -68 |
| Frozen Item 3 focused additions | +16 | 0 | +16 |
| **Item 4 frozen final subtotal** | **445** | **5** | **450** |

The arithmetic is exact: `497 - 68 + 16 = 445` root methods; provider-package pure coverage remains `5`; and `445 + 5 = 450`. The frozen counted total remains below the provisional `500`-method ceiling by `50` methods. No deletion quota or minimum was used: each `-68` reduction is the Item 2 value-reviewed scenario-preserving consolidation or obsolete-contract removal, and each `+16` addition is the Item 3 confirmed current-contract protection.

### Exact final validation-class totals

All approved Item 3 additions are behavioral coverage. Structural and diagnostic allocations are unchanged from the Item 2 exception review.

| Target | Behavioral coverage | Structural/deletion guard | Diagnostic benchmark | Final subtotal |
| --- | ---: | ---: | ---: | ---: |
| Root `RepoPromptTests` | 432 | 12 | 1 | 445 |
| Nested `RepoPromptClaudeCompatibleProviderTests` | 5 | 0 | 0 | 5 |
| **Counted total** | **437** | **12** | **1** | **450** |

| Validation class | Freeze rationale |
| --- | --- |
| Behavioral coverage — `437` | Primary allocation: executable current CE outputs, rejection boundaries, transformations, integrations, and external contracts. The `+16` approved additions close confirmed current gaps without adding dead façade, legacy, or future-provider coverage. |
| Structural/deletion guard — `12` | The plan's review trigger is exceeded (`12 > 10`), so the explicit Item 2 inventory is re-accepted at freeze: `4` MCP guards preserve prohibited unsafe/incomplete routing paths, copied CLI/help exposure, and removed namespaces; `4` AgentMode/AI guards preserve the single provider-package importer, strict Oracle reporting/planning wiring, and removed migration paths; `3` WorkspaceContext/Services guards preserve runtime-search cutover, DEBUG loading-diagnostics layering, and deferred scan-flush ownership; `1` Prompt guard preserves the removed prompt-mirror boundary and canonical source ownership. Existing behavioral tests do not cheaply prove these absence, ownership, layering, or copied-exposure constraints. |
| Diagnostic benchmark — `1` | Below the `>2` review trigger. Retain the DEBUG/opt-in transcript crawl-refresh benchmark as a measurement harness, separately classified from behavioral protection. |
| Live smoke | Uncounted. Retain CE CLI smoke and add the targeted `manage_worktree op=list` vertical below without charging the XCTest census. |

### Exact frozen root-domain allocation

| Root domain | Current census | Frozen Item 2 delta | Frozen Item 3 addition | Final methods |
| --- | ---: | ---: | ---: | ---: |
| `AI` | 30 | -9 | 0 | 21 |
| `AgentMode` | 103 | -6 | +5 | 102 |
| `App` | 2 | 0 | +3 | 5 |
| `Chat` | 6 | -5 | 0 | 1 |
| `CodeMap` | 10 | -4 | 0 | 6 |
| `Diagnostics` | 1 | 0 | 0 | 1 |
| `Diffing` | 11 | -3 | +1 | 9 |
| `MCP` | 119 | -18 | +1 | 102 |
| `Prompt` | 22 | -5 | 0 | 17 |
| `Root` | 33 | -1 | 0 | 32 |
| `Security` | 12 | -1 | +3 | 14 |
| `Services` | 54 | -11 | 0 | 43 |
| `WorkspaceContext` | 94 | -5 | +3 | 92 |
| **Root subtotal** | **497** | **-68** | **+16** | **445** |

The nested provider package remains `5 → 5`: no provider-package test or source edit is approved. Its pure protocol/runtime/catalog ownership stays separate from root bridge, adapter, launch-environment, permission, and lifecycle coverage.

### Explicit freeze choice 1 — `VCS-C03` is exactly `-1`

`VCS-C03` is no longer conditional. Review of the focused VCS suites confirms that all bundled scenarios fit existing focused declarations without a new XCTest method.

**Remove exactly one declaration atomically with replacement assertions:**

- `Tests/RepoPromptTests/Services/VCS/GitWorktreeMergeEndToEndTests.swift`
  - remove `testPreviewDirtySourceCleanApplyAndStalePreviewWithRealWorktrees()`
  - retain `testConflictApplyReconcileAbortAndManualContinueWithRealWorktrees()` unchanged, including its reloaded `.applying` conflict reconciliation, abort, and manual-continue vertical

**Extend existing focused owners atomically:**

| Preserved bundled scenario | Exact surviving owner and required edit |
| --- | --- |
| Clean artifact-publishing preview → apply compatibility | Extend `GitWorktreeMergeGitServiceTests.testVCSPreviewApplyCompletesCleanMerge()`: call `preview(publishArtifacts: true)`, `XCTUnwrap(preview.artifacts)` before apply, and retain completed-status, merge-commit, merged-content, and two-parent assertions. |
| Artifact publication details | Retain `GitWorktreeMergePreviewPublisherTests.testPreviewPublishesDiffSnapshotAndMergeSidecar()` unchanged. It already owns manifest, map, sidecar, patch, JSON heads, operation ID, summary, and visualization detail. |
| Dirty source blocker | Append an independent second `GitMergeFixture` scenario to `GitWorktreeMergeGitServiceTests.testVCSPreviewApplyCompletesCleanMerge()`: create an uncommitted source file, preview without artifacts, and assert blocked inspection with `.sourceDirty`. Use a separate fixture so dirty state cannot weaken clean-apply assertions. |
| Stale target no-mutation evidence | Extend the target-stale subsection of `GitWorktreeMergeGitServiceTests.testVCSApplyRejectsStaleSourceAndTargetHeads()`: after the intentional target commit capture `HEAD`, `HEAD^{tree}`, and `status --porcelain`; after apply retain `.stale`, stale-reason, and absent-source assertions and prove all three captured values are unchanged. |

| VCS-C03 suite | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `GitWorktreeMergeEndToEndTests` | 2 | 1 | -1 |
| `GitWorktreeMergeGitServiceTests` | 10 | 10 | 0 |
| `GitWorktreeMergePreviewPublisherTests` | 1 | 1 | 0 |
| **VCS-C03 exact total** | **13** | **12** | **-1** |

**Atomicity rule:** do not land deletion-first. Freeze one atomic sub-batch containing the two Git-service extensions and bundled-method removal.

### Explicit freeze choice 2 — retain one AgentMode provider-cancel matrix method

Keep the approved Claude-native plus ACP controller cancel cleanup protection as **one** table/matrix-oriented XCTest declaration in the new `AgentModeRunServiceLifecycleTests.swift`. Do not split it into two declarations.

The two named rows protect one service-level `AgentModeRunService.cancelRun` contract:

1. common MCP-tool cancellation is requested before provider shutdown;
2. the provider-specific runtime/controller reference clears immediately;
3. cleanup reaches the old runtime.

The Claude-native row covers synchronous controller clearing plus resume-transfer cleanup. The ACP row covers `acpController` clearing plus `cancelPrompt()` and `shutdown()`. Named rows preserve diagnostic clarity. A second declaration would improve naming only, not add a distinct behavior boundary. Codex common cancellation remains protected indirectly by the retained `AgentModeStopSubmitTargetTests` layer and is not duplicated.

| New `AgentModeRunServiceLifecycleTests` declaration | Delta |
| --- | ---: |
| Startup-failure state transition | +1 |
| Current Codex / Claude-native / ACP provider dispatch matrix | +1 |
| Claude queued-steering success/failure restoration matrix | +1 |
| ACP queued-steering ordering/restoration method | +1 |
| Claude-native / ACP provider-specific cancel cleanup matrix | +1 |
| **AgentMode lifecycle exact total** | **+5** |

The rejected split is not an implementation fallback. If later work identifies a genuinely distinct contract that requires another method, stop and revise this freeze instead of silently moving to `451`.

### Exact minimal deterministic seams frozen for later implementation

Only these two behavior-preserving production seams are approved. No other source redesign, target-dependency change, or CLI production seam is authorized.

| Seam | Exact later source edit | Why required | Validation |
| --- | --- | --- | --- |
| Slice partition base URL injection | `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/PartitionStore.swift`: add an instance `baseURL`, initialize it with an internal initializer defaulting to the existing `Self.partitionsBaseURL()`, and make `partitionURL(forRoot:scope:)` use the instance value. | Allows deterministic temporary-directory cold reload/isolation coverage without global override or writes to real Application Support. Production default behavior remains unchanged. | `make dev-test FILTER=SelectionSlicePersistenceAndRebaseTests`; `make dev-swift-build PRODUCT=RepoPrompt` |
| AgentMode run-service MCP-idle waiter injection | `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`: add a narrow `AgentModeRunServiceMCPIdleWaiter` closure dependency, store it as an optional property, set production initialization to `nil`, add DEBUG initializer parameter `testAgentModeRunServiceMCPIdleWaiter: AgentModeRunServiceMCPIdleWaiter? = nil`, and use the override in `makeRunService()` or fall back to the current `mcpServer?.awaitNoActiveToolExecutions(runID:)` behavior. | Required to record deterministic idle-before-send ordering in the approved Claude and ACP steering tests. The current view-model construction hardwires the MCP server waiter. | `make dev-test FILTER=AgentModeRunServiceLifecycleTests`; adjacent AgentMode lanes; `make dev-swift-build PRODUCT=RepoPrompt`; applicable uncounted CE smoke |

`AgentModeRunService.swift` itself does not need a seam edit: its `Dependencies.awaitNoActiveMCPTools` closure already exists. `SliceRebaseEngine.swift` does not need a seam edit. The DEBUG CLI `--test-parse` hook already exists and must be reused unchanged.

### Frozen implementation sequence

Use the following small dependency-safe sequence for later Item 5 work. The numbered batches are ordered. Sub-batches within Batch 1 and Batch 2 are non-overlapping and may be implemented independently, but each sub-batch must reconcile its own delta and pass its focused coordinated validation before the next dependent step. Any Swift batch follows the repository formatting workflow: run `make dev-format` when the intended Swift edits are complete, then `make dev-lint` before handoff.

#### Batch 1 — land focused replacement protection and the two minimal seams first (`+16` root)

This additive batch lands before reductions. It closes every approved current-contract gap and ensures later reshaping never temporarily removes required protection.

| Sub-batch | Exact touched files/modules | Frozen delta | Required coordinated validation lanes |
| --- | --- | ---: | --- |
| **1A — Diff routing / ApplyEdits** | Extend `Tests/RepoPromptTests/MCP/ApplyEdits/ApplyEditsCoreRecoveryTests.swift` with the combined unmatched single/batch contract and strengthen the existing exact ambiguity assertion; add `Tests/RepoPromptTests/Diffing/DiffGenerationUtilityRoutingTests.swift` for `replaceAll` duplicate-match bypass plus cumulative offsets. | +2 behavioral | `make dev-test FILTER=ApplyEditsCoreRecoveryTests`; `make dev-test FILTER=DiffGenerationUtilityRoutingTests` |
| **1B — Security and App close policy** | Add `Tests/RepoPromptTests/Security/DebugSecureStorageRuntimePolicyTests.swift`; extend `Tests/RepoPromptTests/Security/KeychainServiceTests.swift` with update-success/no-add and update-missing/add-success write methods; add `Tests/RepoPromptTests/App/WindowCloseCoordinatorDecisionTests.swift`. | +6 behavioral | `make dev-test FILTER=DebugSecureStorageRuntimePolicyTests`; `make dev-test FILTER=KeychainServiceTests`; `make dev-test FILTER=WindowCloseCoordinatorDecisionTests` |
| **1C — Slice persistence / rebase** | Add `Tests/RepoPromptTests/WorkspaceContext/Slices/SelectionSlicePersistenceAndRebaseTests.swift`; add only the frozen instance-base-URL seam in `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/PartitionStore.swift`. | +3 behavioral | `make dev-test FILTER=SelectionSlicePersistenceAndRebaseTests`; `make dev-swift-build PRODUCT=RepoPrompt` |
| **1D — AgentMode lifecycle** | Add `Tests/RepoPromptTests/AgentMode/AgentModeRunServiceLifecycleTests.swift`; add only the frozen DEBUG idle-waiter override in `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift`. Keep provider cancel as one named-row matrix method. | +5 behavioral | `make dev-test FILTER=AgentModeRunServiceLifecycleTests`; `make dev-test FILTER=AgentModeStopSubmitTargetTests`; `make dev-test FILTER=AgentRunWorktreeStartTests`; `make dev-swift-build PRODUCT=RepoPrompt`; record applicable `make dev-smoke` separately, and use credentialed `./conductor smoke --agent-run` only when intentionally available |
| **Batch 1 total** | Root protection additions only; provider package unchanged. | **+16** | Recount expected root subtotal after this batch: `497 + 16 = 513`. This temporary additive subtotal is intentional and replacement-first. |

#### Batch 2 — apply approved scenario-preserving consolidations and obsolete-contract removals (`-68` root)

Batch 2 starts only after Batch 1 protection passes. Each sub-batch is non-overlapping. Transfers and folded assertions land atomically with their declaration removals.

| Sub-batch | Frozen records | Exact touched files | Frozen delta | Required coordinated validation lanes |
| --- | --- | --- | ---: | --- |
| **2A — MCP reshaping** | `MCP-CONS-01` through `MCP-CONS-16` | `Tests/RepoPromptTests/MCP/BindContextRoutingRecoveryTests.swift`; `MCP/AgentRunWorktreeStartTests.swift`; `MCP/TabContextRoutingTests.swift`; `MCP/ManageWorktreeToolServiceTests.swift`; `MCP/ToolOutputFormatterWorktreeTests.swift`. Validate retained owner layers in `MCP/ToolCatalogSnapshotTests.swift` and `MCP/WorktreeAPISmokeHarnessTests.swift` without weakening their contracts. | -18 | `make dev-test FILTER=BindContextRoutingRecoveryTests`; `make dev-test FILTER=AgentRunWorktreeStartTests`; `make dev-test FILTER=TabContextRoutingTests`; `make dev-test FILTER=ManageWorktreeToolServiceTests`; `make dev-test FILTER=ToolCatalogSnapshotTests`; `make dev-test FILTER=ToolOutputFormatterWorktreeTests`; `make dev-test FILTER=WorktreeAPISmokeHarnessTests` |
| **2B — AgentMode / AI matrices** | `C1` through `C13` | `Tests/RepoPromptTests/AgentMode/RecommendationProviderFilterNormalizationTests.swift`; `AgentMode/AgentWorkspaceRootsSidebarStoreTests.swift`; `AgentMode/AgentWorktreeMergeAttentionTests.swift`; `AgentMode/Transcript/AgentToolResultPersistencePolicyTests.swift`; `AgentMode/Transcript/AgentTranscriptActivationRepaintRemountPolicyTests.swift`; `AI/AIModelPreferenceRegressionTests.swift`; `AI/AIQueriesServiceCodexPolicyTests.swift`; `AI/CodexCLIProviderThreadPolicyTests.swift`; `AI/CodexNativeSessionControllerInterruptTests.swift`; `AI/CodexNativeSessionControllerThreadStartTests.swift`. Preserve per-row isolation/shutdown and do not collapse rejected `R1` or `R2`. | -15 | Run `make dev-test FILTER=<TouchedSuite>` for each touched suite named at left. No provider-package lane is needed for this sub-batch because no provider-package file changes. |
| **2C — WorkspaceContext / Services including atomic VCS-C03** | `WS-STORE-C01` through `WS-STORE-C04`; `WS-SEL-C01`; `FS-C01`; `VCS-C01`; `VCS-C02`; exact `VCS-C03` | `Tests/RepoPromptTests/WorkspaceContext/WorkspaceFileContextStoreTests.swift`; `WorkspaceContext/WorkspaceSelectionCoordinatorTests.swift`; `Services/FileSystem/FileSystemServiceEventPathMappingTests.swift`; `Services/VCS/GitRepoTargetResolverTests.swift`; `Services/VCS/GitWorktreePorcelainParserTests.swift`; `Services/VCS/GitWorktreeMergeEndToEndTests.swift`; `Services/VCS/GitWorktreeMergeGitServiceTests.swift`. Validate `Services/VCS/GitWorktreeMergePreviewPublisherTests.swift` unchanged. The VCS-C03 focused extensions land atomically with its bundled-method removal. | -16 exact | `make dev-test FILTER=WorkspaceFileContextStoreTests`; `make dev-test FILTER=WorkspaceSelectionCoordinatorTests`; `make dev-test FILTER=FileSystemServiceEventPathMappingTests`; `make dev-test FILTER=GitRepoTargetResolverTests`; `make dev-test FILTER=GitWorktreePorcelainParserTests`; `make dev-test FILTER=GitWorktreeMergeGitServiceTests`; `make dev-test FILTER=GitWorktreeMergeEndToEndTests`; `make dev-test FILTER=GitWorktreeMergePreviewPublisherTests` |
| **2D — remaining root domains** | `REM-CODEMAP-01` through `REM-CODEMAP-04`; `REM-CHAT-01`; `REM-DIFF-01`; `REM-DIFF-02`; `REM-PROMPT-01` through `REM-PROMPT-03`; `REM-SECURITY-01`; `REM-ROOT-01` | `Tests/RepoPromptTests/CodeMap/CodeMapGoldenTests.swift`; `CodeMap/FileViewModelAcceptedCodeMapTests.swift`; `Chat/ChatNameExtractorTests.swift`; `Diffing/DiffChunkTextApplierTests.swift`; `Prompt/PromptContextResolvedFileTreeTests.swift`; `Prompt/PromptMigrationRemovalTests.swift`; `Prompt/PromptResourceMirrorRemovalTests.swift`; `Security/AgentPermissionSecureStoreTests.swift`; `WorkspaceRootSyncTests.swift`. Preserve all 13 CodeMap fixture/golden rows and caps `≤5`, `≤5`, `≤3`. | -19 | `make dev-test FILTER=CodeMapGoldenTests`; `make dev-test FILTER=FileViewModelAcceptedCodeMapTests`; `make dev-test FILTER=ChatNameExtractorTests`; `make dev-test FILTER=DiffChunkTextApplierTests`; `make dev-test FILTER=PromptContextResolvedFileTreeTests`; `make dev-test FILTER=PromptMigrationRemovalTests`; `make dev-test FILTER=PromptResourceMirrorRemovalTests`; `make dev-test FILTER=AgentPermissionSecureStoreTests`; `make dev-test FILTER=WorkspaceRootSyncTests` |
| **Batch 2 total** | All Item 2 reductions. | Root tests only. | **-68** | Recount expected root subtotal after Batch 2: `513 - 68 = 445`. |

#### Batch 3 — add uncounted CLI executable harness and live parser-to-forwarding smoke (`+0` counted XCTest)

Keep this script-only work separate from counted XCTest arithmetic and from the root/provider target dependencies.

| Work | Exact later touched files | Frozen implementation | Validation lane |
| --- | --- | --- | --- |
| Deterministic executable parser harness | Add `Scripts/test_repoprompt_mcp_parse_harness.py`. | Invoke the coordinated DEBUG `repoprompt-mcp` artifact with existing `--test-parse` for (1) `manage_worktree op=list include_graph=true graph_limit=8`, asserting `success == true`, `command == "aliasCall"`, `toolName == "manage_worktree"`, and converted arguments; and (2) `manage_worktree {"op":"list"}`, asserting `success == true`, `command == "call"`, `toolName == "manage_worktree"`, and preserved JSON payload. Accept the binary path explicitly, defaulting to `.build/debug/repoprompt-mcp`. | `make dev-swift-build PRODUCT=repoprompt-mcp` (`build` lane), then `python3 Scripts/test_repoprompt_mcp_parse_harness.py .build/debug/repoprompt-mcp` |
| Live shorthand parser-to-forwarding vertical | Extend `Scripts/conductor.py` `operation_smoke` stages and add a mocked regression in `Scripts/test_conductor_lifecycle.py`. | Add `rpce-cli-debug -w <window> -e 'manage_worktree op=list'` after `tree --type roots` and before the direct `agent_manage` stage. Preserve existing live stages. The Python regression asserts the shorthand stage is invoked in that ordering. | `make conductor-selftest`; `make dev-smoke` (`debugArtifact`, `liveApp` lanes), or `make dev-smoke-launch` (`build`, `debugArtifact`, `liveApp`) only when intentional relaunch is acceptable |

No `RepoPromptTests` dependency on the `RepoPromptMCP` executable is approved. No `Package.swift` edit, `Makefile` edit, parser extraction, or new CLI production seam is approved. The new parser harness is intentionally invoked explicitly after the coordinated MCP build because it requires that artifact; it is not added to artifact-independent `conductor-selftest`. The existing DEBUG `--test-parse` hook remains the deterministic seam. Batch 3 changes the counted allocation by `+0`.

#### Batch 4 — final acceptance and ledger evidence

After Batches 1–3 reconcile, append actual command results and the final recount to this ledger.

```bash
make dev-format          # after intended Swift edits
make dev-lint
make dev-test
make dev-provider-test
make dev-swift-build PRODUCT=RepoPrompt
make dev-swift-build PRODUCT=repoprompt-mcp
python3 Scripts/test_repoprompt_mcp_parse_harness.py .build/debug/repoprompt-mcp
make conductor-selftest
make guardrails
make dev-smoke
```

Use `make dev-smoke-launch` only when intentional app relaunch is acceptable. Record credentialed `./conductor smoke --agent-run` separately only when provider credentials and model access are intentionally available.

Expected acceptance recount:

| Target | Frozen final methods |
| --- | ---: |
| Root `RepoPromptTests` | 445 |
| Nested `RepoPromptClaudeCompatibleProviderTests` | 5 |
| **Counted total** | **450** |

### Item 4 completion and Item 5 handoff

- **Item 4 is complete:** the exact final allocation is frozen at **`445 root + 5 provider = 450`**; final classes reconcile to **`437 behavioral + 12 structural + 1 diagnostic = 450`**.
- **`VCS-C03` is frozen at `-1`**, not conditional. Its focused replacement assertions and bundled-method removal land in one atomic sub-batch.
- **AgentMode provider-specific cancellation remains one matrix declaration**. The lifecycle addition remains exactly `+5`; the optional split is deliberately rejected because it adds no distinct service-level contract.
- The two approved production seams are exact and minimal: `PartitionStore` instance base-URL injection and DEBUG-only `AgentModeViewModel` run-service idle-waiter injection. No other source seam is approved.
- The CLI executable parser harness and live `manage_worktree op=list` smoke stage are frozen as uncounted Batch 3 work. They do not alter `R`, `P`, or validation-class totals.
- Later Item 5 implementation must reconcile each batch delta before continuing, preserve the linked Item 2 scenario rows, and stop for a ledger revision rather than silently changing the frozen method allocation.
- No Swift file, script, `Makefile`, or unrelated administration file was edited and no validation lane was run during Item 4.

## Item 5 authoritative landed reconciliation and acceptance evidence

### Scope boundary and authority

This section is the final Item 5 record. The ignored Item 5 shard and review reports remain working evidence only; this ledger is the single authoritative audit artifact. Item 5 executed the frozen dependency-safe batches, reconciled actual declaration deltas, incorporated Oracle-review corrections, recorded the CLI harness/smoke work separately from XCTest arithmetic, and completed all non-live acceptance lanes. No nested provider-package declaration changed.

The Item 4 batch plan remains above as historical freeze evidence. Where implementation review changed a proposed seam disposition, the final landed disposition below supersedes the earlier proposal.

### Actual landed counted batch deltas

| Landed batch | Actual root delta | Provider delta | Reconciliation note |
| --- | ---: | ---: | --- |
| Batch 1A — Diff routing / ApplyEdits protection | +2 | 0 | Added unmatched single/batch protection and the direct `replaceAll` routing owner. |
| Batch 1B — Security / App close-policy protection | +6 | 0 | Added three secure-storage declarations and three pure close-decision declarations. |
| Batch 1C — slice persistence / rebase protection | +3 | 0 | Added cold-reload/isolation and two rebase declarations. |
| Batch 1D — AgentMode lifecycle protection | +5 | 0 | Added the frozen five-method lifecycle matrix; provider-specific cancellation remains one matrix declaration. |
| **Batch 1 replacement-first subtotal** | **+16** | **0** | Root declarations temporarily moved `497 → 513`. |
| Batch 2A — MCP reshaping | -18 | 0 | `MCP-CONS-01` through `MCP-CONS-16` reconciled exactly. |
| Batch 2B — AgentMode / AI matrices | -15 | 0 | `C1` through `C13` reconciled exactly. |
| Batch 2C — WorkspaceContext / Services | -16 | 0 | Includes atomic `VCS-C03` focused assertion transfer and bundled declaration removal at the frozen exact `-1`. |
| Batch 2D — remaining root domains | -19 | 0 | Preserved the 13 CodeMap fixture/golden scenarios and caps while reconciling the remaining frozen records. |
| **Batch 2 reshaping subtotal** | **-68** | **0** | Root declarations moved `513 → 445`. |
| Batch 3 — CLI executable harness / smoke stage | 0 | 0 | Script-only, intentionally uncounted work. |
| Oracle-review corrections and workspace slice-set order follow-up | 0 | 0 | Corrections changed assertions, bounded waits, cleanup, and a test ordering assumption without adding or removing declarations. |
| **Net landed delta from the Item 1 recount** | **-52** | **0** | `497 + 16 - 68 = 445` root; provider remains `5`. |

### Final declaration recount

The final declaration recount uses the ledger policy `^\s*func\s+(test[A-Za-z0-9_]*)\s*\(` under the two counted targets.

| Target | Item 1 current recount | Landed net delta | Final declared methods |
| --- | ---: | ---: | ---: |
| Root `RepoPromptTests` | 497 | -52 | **445** |
| Nested `RepoPromptClaudeCompatibleProviderTests` | 5 | 0 | **5** |
| **Counted total** | **502** | **-52** | **450** |

Final observed recount:

```text
root: 445
provider: 5
total: 450
```

### Final validation-class totals

All Item 3 additions landed as behavioral coverage. The retained structural/deletion-guard and diagnostic-benchmark allocations remain unchanged from the Item 4 freeze.

| Target | Behavioral coverage | Structural/deletion guard | Diagnostic benchmark | Final subtotal |
| --- | ---: | ---: | ---: | ---: |
| Root `RepoPromptTests` | 432 | 12 | 1 | 445 |
| Nested `RepoPromptClaudeCompatibleProviderTests` | 5 | 0 | 0 | 5 |
| **Counted total** | **437** | **12** | **1** | **450** |

### Final production seam and fix disposition

| Production area | Final landed disposition |
| --- | --- |
| `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/PartitionStore.swift` | **Retained.** The narrow instance `baseURL` initializer seam defaults to the existing Application Support partition location and enables deterministic temporary-directory cold reload/isolation coverage without changing shipped default behavior. |
| `Sources/RepoPrompt/Infrastructure/Diffing/DiffGenerationUtility.swift` | **Fixed and covered.** The landed `replaceAll` coordinate correction creates generated chunks at original-file coordinates and leaves cumulative insertion/deletion adjustment to the applier. The direct routing owner covers both positive-delta and negative-delta duplicate-match replacements while retaining the ambiguity contrast when `replaceAll` is false. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` proposed DEBUG idle-waiter hook | **Removed as unnecessary after review.** The lifecycle harness directly constructs `AgentModeRunService.Dependencies(awaitNoActiveMCPTools:)`; the proposed view-model override was redundant and leaves no net source diff. |

The final landed production-source diff is limited to `PartitionStore.swift` and `DiffGenerationUtility.swift`.

### CLI executable harness and smoke work — intentionally uncounted

| Work | Final disposition |
| --- | --- |
| `Scripts/test_repoprompt_mcp_parse_harness.py` | Added the deterministic DEBUG `repoprompt-mcp --test-parse` process harness for shorthand and JSON `manage_worktree` parser cases. Oracle review added a bounded parser timeout with a clear `HarnessError`. The harness passed against `.build/debug/repoprompt-mcp`. |
| `Scripts/conductor.py` and `Scripts/test_conductor_lifecycle.py` | Added the live shorthand stage `manage_worktree op=list` after `tree --type roots` and before direct `agent_manage`, plus the mocked ordering regression. `make conductor-selftest` passed. |
| Count treatment | Script harness and live smoke remain outside the two XCTest targets: **`+0` counted declarations**. No `Package.swift`, `Makefile`, parser extraction, or CLI production seam was added. |

### Oracle-review corrections and acceptance follow-up

The ignored `test-coverage-value-audit-item5-review-corrections-report.md` records the scoped Oracle-review correction pass. The ignored `test-coverage-value-audit-item5-workspace-order-fix-report.md` records the later full-suite follow-up. Together they changed no declaration count.

| Area | Final correction or assessment |
| --- | --- |
| AgentMode lifecycle harness | Added bounded ACP awaits and failure-path cleanup; controller shutdown is reached on success and thrown failure paths. |
| CLI parse harness | Added timeout handling and a clear timeout failure. |
| Diff routing | Folded negative-delta `replaceAll` coverage into the existing direct routing declaration alongside the positive-delta row. |
| Transcript persistence | Restored non-Oracle `error_count` absence and pinned shipped generic `summary_text == "chat_send • success"` behavior. |
| VCS clean preview/apply owner | Strengthened retained artifact coverage with `mapPath` and `sidecarPath` existence assertions. |
| AgentMode view-model seam | Removed the redundant proposed DEBUG idle-waiter hook after review. |
| `manage_worktree` catalog/schema discoverability | Assessed as already satisfied by retained catalog and public-schema owners; no restoration declaration required. |
| Workspace slice-set consolidation | Relaxed an unjustified relative-order assumption for newly appended slice paths to set-membership assertions while retaining preservation and replacement behavior. |

A final scoped Oracle re-review reported no actionable correctness issues in the review-correction diff.

### Final validation evidence

| Command | Final outcome |
| --- | --- |
| `make dev-format` | **Passed.** |
| `make dev-lint` | **Passed.** |
| `make dev-test` | **Passed.** Full coordinated root suite. |
| `make dev-provider-test` | **Passed.** Nested provider-package suite. |
| `make dev-swift-build PRODUCT=RepoPrompt` | **Passed.** |
| `make dev-swift-build PRODUCT=repoprompt-mcp` | **Passed.** |
| `python3 Scripts/test_repoprompt_mcp_parse_harness.py .build/debug/repoprompt-mcp` | **Passed.** |
| `make conductor-selftest` | **Passed.** |
| `make guardrails` | **Passed.** |
| `make dev-smoke` | **Attempted, blocked because the CE debug app was unavailable. Not passed.** |

Live CE smoke remains **pending** a user-approved disruptive `make dev-smoke-launch` (or equivalent intentional launch). It must not be represented as passed. Credentialed `./conductor smoke --agent-run` remains separate and was not claimed.

### Item 5 completion

- **Counted acceptance is complete:** final recount is **`445 root + 5 provider = 450`**.
- **Class reconciliation is complete:** **`437 behavioral + 12 structural + 1 diagnostic = 450`**.
- **Production disposition is complete:** retain the `PartitionStore` base-URL seam, retain the covered `DiffGenerationUtility.replaceAll` coordinate fix, and remove the unnecessary proposed AgentMode view-model hook.
- **CLI work is complete and uncounted:** parser harness and mocked smoke ordering passed; the live stage remains unexecuted because the CE app was unavailable.
- **Non-live validation is complete:** formatting, lint, both XCTest suites, both product builds, parser harness, conductor self-test, and guardrails passed.
- **Live smoke is pending user-approved disruptive launch, not passed.**

## Scenario and fixture breadth index

The Item 1 census rows with a non-empty scenario or fixture note are listed here as a compact consolidation-safety index. Each counted once in the census.

| Target | File | Method | Scenario / fixture breadth hidden behind one declaration |
| --- | --- | --- | --- |
| `RepoPromptTests` | `AI/AIModelPreferenceRegressionTests.swift` | `testLegacyMCPPlanningModelMigrationSymbolAndStartupCallAreRemoved` | Source-shape loop: 2 source files x 3 removed identifiers. |
| `RepoPromptTests` | `AgentMode/ClaudeCompatible/ClaudeCompatiblePluginBridgeTests.swift` | `testOnlyBridgeImportsProviderPackage` | Dynamically enumerates `Sources/RepoPrompt/**/*.swift`; expects exactly one provider-package importer. |
| `RepoPromptTests` | `AgentMode/ClaudeCompatible/ClaudeCompatiblePluginBridgeTests.swift` | `testBridgeRuntimeSmokeMapsPluginIDsDiscoveryRuntimeAndHeadlessAdapters` | Table loop: 4 provider/plugin mappings (Claude, GLM, Kimi, custom), then GLM discovery config assertions. |
| `RepoPromptTests` | `AgentMode/Transcript/AgentToolResultPersistencePolicyTests.swift` | `testConfirmedOracleSendToolNamesPersistBoundedStructuredSummaries` | Table loop: 2 equivalent Oracle-send tool names (`ask_oracle`, `oracle_send`). |
| `RepoPromptTests` | `AgentMode/Transcript/AgentTranscriptCrawlRefreshBenchmarkTests.swift` | `testLongActiveCrawlFinalTurnRefreshBenchmarkReport` | Opt-in DEBUG benchmark: 40 tool-result pairs, >=24 KiB payloads, 1 warmup + 9 measured refresh samples; emits report. |
| `RepoPromptTests` | `CodeMap/CodeMapGoldenTests.swift` | `testCEFixturesMatchGoldenCodeMapDescriptions` | Golden helper loop: 5 CE fixtures (C, Go, Python, Swift, TypeScript). |
| `RepoPromptTests` | `CodeMap/CodeMapGoldenTests.swift` | `testExpandedLanguageFixturesMatchGoldenCodeMapDescriptions` | Golden helper loop: 5 expanded fixtures (Dart, Java, JavaScript, Ruby, Rust). |
| `RepoPromptTests` | `CodeMap/CodeMapGoldenTests.swift` | `testCodeMapEdgeFixturesPreserveExportsTypesAndMethods` | Golden helper loop: 3 edge fixtures (C++, PHP, TSX). |
| `RepoPromptTests` | `MCP/AgentRunMCPToolServiceWaitAnyTests.swift` | `testWaitAnySteeringInterruptValueShapeOmitsNonTerminalAssistantText` | Builds and inspects 2 session snapshots; loop verifies omitted assistant text. |
| `RepoPromptTests` | `MCP/ApplyEdits/ApplyEditsCoreRecoveryTests.swift` | `testRequestBuilderAcceptsBatchPayloadShapes` | Table loop: 4 accepted payload shapes (array, object, JSON string, wrapped args JSON). |
| `RepoPromptTests` | `MCP/CECLINamingAndRoutingTests.swift` | `testNamedSourcesDoNotAdvertiseStaleDebugCommandNames` | Source-shape enumeration: 8 fixed sources + dynamic workflow-prompt sources checked against 7 stale names. |
| `RepoPromptTests` | `MCP/CECLINamingAndRoutingTests.swift` | `testProviderNeutralWorkflowPromptSourcesReplacedLegacyWorkflowPromptFile` | Dynamically enumerates `Sources/RepoPrompt/**/*.swift` for removed namespace references. |
| `RepoPromptTests` | `MCP/CodexIntegration/CodexIntegrationConfigurationTests.swift` | `testToolTimeoutMutationAcceptsIntegerRadixAndSignVariants` | Table loop: 4 integer spellings (signed decimal, hex, octal, binary). |
| `RepoPromptTests` | `MCP/ManageWorktreeToolServiceTests.swift` | `testManageWorktreeSchemaIncludesMergeOpsAndFields` | Schema table loop: 5 merge operations and 8 fields. |
| `RepoPromptTests` | `MCP/ToolCatalogSnapshotTests.swift` | `testWorktreePublicAPISchemaFieldsRemainAdvertised` | Schema tables: 8 general manage-worktree fields, 8 merge fields, 11 agent-run worktree fields. |
| `RepoPromptTests` | `PresetJSONOnlyPersistenceTests.swift` | `testMissingPresetJSONCreatesEmptyDocumentsAndIgnoresLegacyDefaults` | Fixture breadth: seeds 4 legacy defaults and verifies they are ignored. |
| `RepoPromptTests` | `PresetJSONOnlyPersistenceTests.swift` | `testPresetSaveWritesJSONOnlyAndDoesNotWriteLegacyMirrorKeys` | Fixture breadth: verifies absence of 10 legacy mirror/default keys after save. |
| `RepoPromptTests` | `Prompt/PromptMigrationRemovalTests.swift` | `testLegacyCopyOverridesAndCustomizationsIgnoreRemovedFields` | Table loop: 3 removed JSON keys across 2 encoded document forms. |
| `RepoPromptTests` | `Prompt/PromptResourceMirrorRemovalTests.swift` | `testSourcesAndTestsDoNotReferenceBundledPromptMirror` | Dynamically enumerates Swift sources/tests and checks 2 forbidden bundled-mirror path fragments. |
| `RepoPromptTests` | `Prompt/WorkflowPromptCatalogTests.swift` | `testCatalogMetadataMatchesWorkflowIDs` | Catalog loop: all 9 workflow descriptors. |
| `RepoPromptTests` | `Prompt/WorkflowPromptCatalogTests.swift` | `testRenderedManagedPromptFrontmatterCompatibility` | Catalog loop: 9 install descriptors. |
| `RepoPromptTests` | `Prompt/WorkflowPromptCatalogTests.swift` | `testAgentWorkflowTemplatesRenderFromProviderNeutralCatalog` | Enum loop: every `AgentWorkflow` case; count intentionally derived from current enum. |
| `RepoPromptTests` | `Security/AgentPermissionSecureStoreTests.swift` | `testAccessModesCapturedForPlainReadsWritesAndDeletesOnly` | Enum loop: failure/reset behavior across every `AgentPermissionSecureDomain` case. |
| `RepoPromptTests` | `Security/AgentPermissionSecureStoreTests.swift` | `testRemovedGeminiPermissionDocumentsAreIgnoredDuringReset` | Enum loop: reset failures across every secure domain while removed Gemini key stays untouched. |
| `RepoPromptTests` | `WorkspaceContext/PathMatching/PathMatchingRecoveryTests.swift` | `testAliasAndAbsoluteResolutionStayScopedToTheMatchingRoot` | Snapshot fixture: 3 file records across 2 roots. |
| `RepoPromptTests` | `WorkspaceContext/PathMatching/PathMatchingRecoveryTests.swift` | `testUnicodeAndCaseInsensitiveLookupPreserveStoredRelativePath` | Snapshot fixture: 2 Unicode file records. |
| `RepoPromptTests` | `WorkspaceContext/ReplayEvidenceHarnessTests.swift` | `testFocusedLargeBurstRoutesImmediateWithCappedDefaultChunks` | Generated load: 600 file-add deltas; expects 6 x 100 replay chunks. |
| `RepoPromptTests` | `WorkspaceContext/ReplayEvidenceHarnessTests.swift` | `testUnfocusedBurstQueuesAndDeferredDrainUsesConfiguredChunks` | Generated load: 250 queued file-add deltas; expects chunks 100, 100, 50. |
| `RepoPromptTests` | `WorkspaceContext/ReplayEvidenceHarnessTests.swift` | `testRemovedFolderBurstUsesOneBatchedDescendantLookup` | Generated load: 60 folder adds then 60 folder removals; expects one descendant lookup. |
| `RepoPromptTests` | `WorkspaceContext/ReplayEvidenceHarnessTests.swift` | `testRemovedFolderCleanupFlushesBeforeSamePathFileAdd` | Two-delta ordering scenario: folder removal then same-path file add in one replay chunk. |
| `RepoPromptTests` | `WorkspaceContext/Search/SearchPathFilteringTests.swift` | `testCancelledTaskReportsCancellationMetadata` | Generated load: 50,000 path snapshots to exercise cancellation metadata. |
| `RepoPromptTests` | `WorkspaceContext/WorkspaceFileContextStoreTests.swift` | `testCancelledRootLoadAfterUIRootAppendDoesNotLeaveUIOrStoreRoot` | Generated load: writes 1,500 Swift files before cancellation cleanup assertions. |
| `RepoPromptTests` | `WorkspaceContext/WorkspaceFileContextStoreTests.swift` | `testCallerCancelledLoadFolderAfterUIRootAppendCleansUIAndStoreRoot` | Generated load: writes 1,500 Swift files before caller-driven cancellation cleanup assertions. |
| `RepoPromptTests` | `WorkspaceContext/WorkspaceLoadingDiagnosticsGuardTests.swift` | `testDebugDiagnosticsExposeStoreBackedLoadingSnapshot` | Dynamically enumerates debug-diagnostics source fragments before checking required markers. |
| `RepoPromptClaudeCompatibleProviderTests` | `Runtime/ClaudeCompatibleRuntimeSupportTests.swift` | `testRuntimeLaunchAndHeadlessSmokesPromptEnvironmentAndModels` | Multi-scenario smoke: prompt modes, normalized GLM env, GLM + Kimi resolver cases, headless args fixture. |
| `RepoPromptClaudeCompatibleProviderTests` | `Runtime/ClaudeCompatibleRuntimeSupportTests.swift` | `testProviderCatalogDefaultsExposeStableRawValues` | Catalog breadth: 4 provider raw values, 4 runtime mappings, 4 model-catalog snapshots. |
| `RepoPromptClaudeCompatibleProviderTests` | `SDK/ClaudeSDKNDJSONTranslatorTests.swift` | `testAssistantToolAndResultSmokePreservesUsageArgsAndStableInvocationID` | NDJSON fixtures: assistant usage/text/tool-use plus matching user tool-result invocation ID. |
| `RepoPromptClaudeCompatibleProviderTests` | `SDK/ClaudeSDKNDJSONTranslatorTests.swift` | `testLifecycleAndStreamSmokeCoversSessionCancellationDeltaStopAndContextUsage` | NDJSON fixtures: init, message-start usage, text delta, message stop, cancelled result. |
| `RepoPromptClaudeCompatibleProviderTests` | `SDK/ClaudeSDKProtocolCodecTests.swift` | `testProtocolCodecSmokeDecodesControlRepairsControlCharactersAndEncodesUserMessage` | Protocol fixtures: permission decode, raw-newline repair/decode, user-message encode. |

## Exhaustive executable XCTest census

The Item 1 census listed every counted declaration as one row: 497 in the root `RepoPromptTests` target and 5 in the nested `RepoPromptClaudeCompatibleProviderTests` target. Each row recorded the method, its file and declaration line, the target and domain, a suite-scoped primary contract ID, secondary traceability tags, a provisional validation class and layer, any scenario or fixture breadth note, and an Item 1 tentative disposition. Items 2 to 5 superseded every tentative disposition. The rows with breadth notes are in the scenario and fixture breadth index above. The manifest's SHA-256 is under "Recount evidence", and the recount script there counts the same declarations from the checkout the audit counted. The full rows are in upstream commit `30d8ae319`.

## Item 1 reconciliation

| Check | Result |
| --- | --- |
| Root census row count | **497** current rows (full rows in upstream commit `30d8ae319`). This does **not** equal the plan baseline of 478; drift is reported above. |
| Provider census row count | **5** current rows (full rows in upstream commit `30d8ae319`); matches the plan baseline of 5. |
| Total census row count | **502** current rows (full rows in upstream commit `30d8ae319`); historical plan baseline was 483. |
| Exactly-once ownership | Passed: generated `target + file + declaration line + method name` keys are unique and one census row was emitted for every anchored declaration match. |
| Scenario/golden breadth | Captured independently in the breadth index and repeated in the matching census rows in upstream commit `30d8ae319`. |
| Swift edits during Item 1 | None. Item 5 landed the reconciled changes recorded above. |

## Historical Item 1 handoff — superseded by completed Items 2–5

- Item 1 originally handed detailed retention, deletion, consolidation, retained structural/diagnostic-exception, and cross-layer overlap decisions to Item 2. Those decisions are now complete above.
- The **502-row** manifest remains the pre-edit Item 1 recount. The final Item 5 acceptance recount is **445 root + 5 provider = 450**.
- The historical `478 + 5 = 483` plan baseline remains a comparison point only; the audit did not delete or ignore the 19 current root declarations to manufacture reconciliation.
- The only remaining acceptance lane is live CE smoke, pending a user-approved disruptive launch; it is not recorded as passed.
