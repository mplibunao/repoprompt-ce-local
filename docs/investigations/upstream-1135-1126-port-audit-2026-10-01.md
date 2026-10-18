# Upstream PR 1135 / PR 1126 port: Catalog Contract and Hunk Delta Audit (2026-10-01)

> Investigation report, observed 2026-10-01 on `port/1135-model-catalogs` at `616d67fe` against upstream `48f2b1c0` and `04ab1411`. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/porting.md](../porting.md), Procedure.

This is the source audit that the port's local plan named as its first verification method. It
compares the local stack, layers wi-1 to wi-5, with upstream hunk by hunk. The plan's hunk ledger
gave each upstream hunk a disposition: P (port), A (adapt), D (decline), or X (excluded).
Read-only audit; no build, test, or app run. The live checks for the same port are in
[upstream-1135-1126-live-debug-receipts-2026-10-01.md](upstream-1135-1126-live-debug-receipts-2026-10-01.md).

| Item | Reference |
|---|---|
| Distribution base | `main` = `40716eb1` (merge-base of `main` and `616d67fe`) |
| wi-1 prerequisite (distribution issue #130) | `8dcc4cb8` on `bugfix/codex-approval-available-decisions` (parent `40716eb1`) |
| wi-2 runtime (upstream PR 1126, `04ab1411`) | `0f561463` on `port/1126-codex-0-159-0` (parent `8dcc4cb8`) |
| wi-3 discovery-only GPT-6.1 Sol / Astra | `9e7267ad` (parent `0f561463`) |
| wi-4 Claude 5.x, direct API, OpenRouter, Mythos guard, Anthropic builder | `588c0def` (parent `9e7267ad`) |
| wi-5 recommendations, priorities, seeds | `616d67fe` (parent `588c0def`, head of `port/1135-model-catalogs`) |
| Upstream model support | upstream PR 1135, `48f2b1c0` vs its parent |
| Upstream runtime | upstream PR 1126, `04ab1411` vs its parent |
| Upstream pricing (excluded) | upstream PR 1136, `d69d7291` |

Severity labels: **defect** (code contradicts a decided contract), **ledger drift** (code is
defensible but the plan's ledger or adaptation list does not record it), **coverage gap** (an
identifier or required outcome has no test that asserts it).

## Findings

No defects found. Every upstream hunk has a ledger disposition, and the code matches each
disposition. All decided items hold: no static Codex GPT-6/6.1 cases, Max split without discovery
and Ultra only when advertised, no `extended_context` tag on GPT-6.1 Sol High, Explore on Luna High,
Context Builder on Sol Low, `versionCode` 202_609, and saved selections not rewritten.

| # | Severity | Finding | Code | Upstream anchor or plan reference |
|---|---|---|---|---|
| F1 | coverage gap | The seed helper's chat/Oracle sync branch is untested. When compose is empty, sync is on, and a planning model is set, the planning raw should be copied instead of the provider seed. `APISettingsModelSeedTests` has no sync case. Its only fixture sets a planning model with sync off. | `Sources/RepoPrompt/Features/Settings/ViewModels/APISettingsViewModel.swift:1905-1910`; `Tests/RepoPromptTests/AgentMode/APISettingsModelSeedTests.swift:8-61` | `APISettingsViewModel.swift` hunks `2002`, `2017` (P); a required outcome in the plan |
| F2 | coverage gap | No test asserts the Azure token-limit classification for the 15 GPT-6 entries. These entries now resolve a 128,000 `max_output_tokens` default, where an unlisted model resolved to none. `defaultMaxTokens` and `resolvedMaxTokens` stayed private. `testAzureRefreshVariantsPreserveDeploymentAndEffort` asserts deployment, base model, effort, and the Responses route, but not the cap. | `Sources/RepoPrompt/Infrastructure/AI/Providers/AzureOpenAIProvider.swift:571-573` (`defaultMaxTokens` at 556, `resolvedMaxTokens` at 586) | `AzureOpenAIProvider.swift` hunk `535` (P) |
| F3 | ledger drift | The legacy Anthropic request shape changed for saved custom names that have whitespace or a differently cased suffix. The builder now trims the name and matches `-thinking` and `-thinking-max` case-insensitively for every model, not just the Claude 5 family. Example: `anthropicCustom(" claude-opus-4-8-Thinking ")` used to go to the API verbatim, with no thinking and temperature 0. It now goes as `claude-opus-4-8` with a 16,000 thinking budget, a 32,000 cap, and no temperature. The rows in `testLegacyThinkingRequestShapesRemainUnchanged` assert the new behavior. Upstream left legacy detection case-sensitive and untrimmed. This change is not on the list of known local adaptations. The plan describes trimmed, lowercased matching for classifying the adaptive family and says the legacy column keeps "existing manual-thinking behavior". | `Sources/RepoPrompt/Infrastructure/AI/Providers/AnthropicProvider.swift:205-212, 227-228, 248`; `Tests/RepoPromptTests/AI/AnthropicProviderRequestPolicyTests.swift:84-86` | `AnthropicProvider.swift` hunks `104`, `111`, `128`, `269` |
| F4 | ledger drift | The Mythos guard in `pickContextBuilderFallbackModel` exists and is listed as expected in this audit's brief. The plan's ledger row names only `pickDiffCapableFallback`. | `Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift:6576-6580` | No upstream counterpart |
| F5 | ledger drift | An unlisted test and a DEBUG seam were added. `testContextBuilderFallbackDoesNotCopyRestrictedComposePin` is in `AIModelPreferenceRegressionTests`, a file missing from the plan's test-file table. `test_setAvailableModels` was added to `APISettingsViewModel` under `#if DEBUG` to drive that test. Both support the F4 adaptation. | `Tests/RepoPromptTests/AI/AIModelPreferenceRegressionTests.swift:182`; `APISettingsViewModel.swift:2107` | No upstream counterpart |
| F6 | ledger drift | The runtime layer touches 14 files, but the ledger lists 12. The two extra files are distribution-only tests that assert the bundled version, moved from 0.156.1 to 0.159.0. Upstream `04ab1411` does not touch them, because its copies do not assert the bundled version. | `Tests/RepoPromptTests/AI/CodexRuntimeAuthorityTests.swift:34-35, 49, 301`; `Tests/RepoPromptTests/AgentMode/Codex/CodexExecAgentProviderRuntimePreparationTests.swift:11` | The plan's count of "12 runtime-port files" |
| F7 | coverage gap (inert) | The ordinary OpenAI chat recommendation changed to `gpt-6.1-sol` ("GPT-6.1 Sol via OpenAI API"). It lives in `computeFreeTierChatModelRecommendation`, a private function with no caller in the distribution or upstream. No test covers it, and the change has no runtime effect. | `Sources/RepoPrompt/Features/AgentMode/Recommendations/AutoRecommendationEngine.swift:223, 264-265` | `AutoRecommendationEngine.swift` hunk `261` (P) |
| F8 | coverage gap (low) | `AIModel` equality and hashing go through the static identity (`AIModel.swift:2604-2610`). The direct round-trip tests never assert that two new cases are unequal. A mis-transcribed identity switch, such as `.gpt61SolLow` mapped to `.staticCase(.gpt61Sol)`, would pass them, despite the plan's claim that they would catch it. A mechanical check found the code correct today: all 138 `case .X: .staticCase(.Y)` pairs have X = Y with no duplicate targets, and all 27 new cases have a `StaticIdentity` and a `ModelInfo` entry. | `Sources/RepoPrompt/Infrastructure/AI/AIModel.swift` identity switch | `AIModel.swift` hunks `2018`, `2063`, `2088`, `2189`, `2279`, `2329` |

Other observations, not counted as findings:

- Recommendation copy uses different examples for the same thing. `contextBuilderRationale` says
  "such as GPT-6 Sol Low", while `bestContextBuilder` says "such as GPT-6.1 Sol Low"
  (`RecommendationTypes.swift`). This is a wording-only adaptation, which the brief expects.
- The provider-key-removal reset (`APISettingsViewModel.swift:2147, 2174`) and the
  `pickDiffCapableFallback` last resort (`PromptViewModel.swift:6538`) are tested only through the
  shared helper, which the plan accepts. No test drives those call sites directly.

## Audit requirements

| Requirement | Result |
|---|---|
| Every upstream hunk in the plan's hunk ledger has a disposition | **PASS.** All 85 hunk anchors from `48f2b1c0` (22 files) and all 12 files of `04ab1411` map to a ledger row. Routing anchors 199/218, 7/30 (≈10/33), 54 (≈57), and 703 (≈707) are covered by the ledger's excluded (X) rows. |
| Code matches each disposition | **PASS.** See the hunk tables below. F3 is behavior beyond the stated disposition. |
| Every distribution-added hunk has an upstream counterpart or is a listed local adaptation | **PASS with ledger drift** (F3, F4, F5, F6). No unexplained behavior beyond F3. |
| No unexplained file | **PASS with ledger drift.** Every file is explainable. Three are not in the plan ledger: the two F6 test files and `AIModelPreferenceRegressionTests.swift` (F5). The helpers `CodexDiscoveryTestState.swift` and `IsolatedAPISettingsFixture.swift` are listed adaptations. |
| No generated prompt, review dump, or investigation file committed | **PASS.** No `prompt-exports/`, `reviews/`, or `docs/investigations/` path is in `40716eb1..616d67fe`. |
| Each layer audited against its own parent | **PASS.** wi-3 holds only the Codex discovery identities, wi-4 only Claude, direct, and OpenRouter entries plus the guard and builder, and wi-5 only priorities, recommendations, and seeds. |
| Model layer `0f561463..616d67fe` does not re-include runtime content | **PASS.** It shares no file with `40716eb1..0f561463`, and its added lines contain no `0.159`, `0.156`, manifest, `bundledVersion`, `minimumCodexVersion`, or `availableDecisions`. |
| Negative boundary checks | **PASS.** No `Routing/` or Jev path. Added lines contain no router, routing, Auto-effort, or Jev symbol, no upstream PR 1136 literal (`evidenceVersion`, `rubricVersion`, `$2 input / $10 output`, list-price text), no `1_050_000`, and no `1.05M`. |
| Upstream referenced only as plain text | **PASS.** Commit messages carry `Upstream-Ref: upstream PR 1126 (04ab1411)` and `Upstream-Ref: upstream PR 1135 (48f2b1c0)`. No `owner/repo#N` reference or upstream URL appears in messages or added lines. |
| Identifier matrix with a proving test per identifier | **PASS with coverage gaps** (F1, F2, F7, F8). See the matrix below. |

## Hunk-level comparison

### wi-1 `40716eb1..8dcc4cb8` (14 files)

This is the whole local approval prerequisite and has no upstream counterpart (expected). Its added
lines contain no runtime pin or model identifier. The contract fixture adds the three
`availableDecisions` paths and the schema-gate doc records 45/196/93; the plan
anticipates this increase.

### wi-2 `8dcc4cb8..0f561463` against upstream `04ab1411`

| File | Ledger | Result |
|---|---|---|
| `.github/workflows/ci.yml` | `41` P | Changed lines identical to upstream (npm pin 0.159.0); local gitleaks work untouched |
| `Scripts/Fixtures/codex-app-server-contract.json` | `1` P | Changed lines identical (`minimumCodexVersion` 0.159.0); prerequisite fields kept |
| `Scripts/codex_runtime_artifact.py` | `28` P | Byte-identical to the upstream post-image |
| `Scripts/test_codex_runtime_artifact.py` | 17 anchors A | 42 changed lines identical to upstream; local voice and entitlement fixtures untouched |
| `Scripts/test_codex_update_candidate.py` | `24`, `257`, `418` P | Byte-identical to the upstream post-image |
| `CodexRuntimeAuthority.swift` | `6` P | Changed line identical; local comment and external floor 0.149.0 kept |
| `THIRD_PARTY_NOTICES.md`, `ThirdPartyLicenses/codex/README.md`, `SHA256SUMS` | P / A / A | Byte-identical to upstream post-images; `shasum -c SHA256SUMS` passes 13/13 |
| `Vendor/Codex/manifest.json` | A | Byte-identical to the upstream post-image |
| `docs/architecture/codex-app-server-schema-gate.md` | `21`, `65`, `196` A | Floor and CI pin hunks match; count kept at 45/196/93; dated rotation section appended; local history kept |
| `docs/releasing.md` | `43`, `113`, `140`, `159`, `185` A | Hand-mapped at local lines 315, 375, 403, 421, 445; rollback baseline is the verified 0.156.1 package with upstream's archive digests plus the manifest digest |
| `CodexRuntimeAuthorityTests.swift`, `CodexExecAgentProviderRuntimePreparationTests.swift` | not in ledger | Version assertions only (F6) |

### wi-3 to wi-5 `0f561463..616d67fe` against upstream `48f2b1c0`

| File | Upstream anchors and disposition | Result |
|---|---|---|
| `AgentModel.swift` | 25/128/208 A; 95/181/261 P; 291 D; 327 P; 449/558 A; 636 A; 644 P; 657 A | 11 Codex cases with names and descriptions; no CLI-minimum claim; GPT-6.1 Sol Low description adapted to the local Context Builder wording. Static Codex list unchanged (comment only, line 331). Resolvers at 490/509 and dispatch at 649. Tags: `.gpt61SolHigh, .gpt6SolHigh` with no extended context (733); Sonnet tags moved to Sonnet 5.5 (741). Context metadata: GPT-6.1 and Astra `nil`, Mythos and Sonnet 5.5 1,000,000 (757). Matches. |
| `AgentModelCatalog.swift`, `AgentCodexModelRegistry.swift`, `CodexAIModelCatalog.swift` | 1880, 234, 485 D | Not changed. Matches. |
| `CodexModelSpecifier.swift` | 113 A | `gpt-6.1-sol` and `gpt-6-astra` join the Max-only group (128); GPT-6.1 Ultra static backfill declined. Matches. |
| `ClaudeCompatibleProviderPlugin.swift` | 237/244/268/322 P | Identical to upstream. Matches. |
| `ClaudeCompatibleRuntimeSupportTests.swift` | 170/179/197/234 A | Upstream assertions kept. `defaultModelRaw != mythos` strengthened to `== "opus"`; adds no-Ultra and runtime-argument stripping checks. Matches. |
| `ClaudeCompatibleModelCatalogAdapter.swift` | 387 P | Identical. Matches. |
| `ClaudeCodeAIModelCatalog.swift` | 26/36 P | Identical. Matches. |
| `ClaudeCompatiblePluginBridgeTests.swift` | 31 A | Explicit availability fixture instead of `.current`; package, Agent, and chat agreement; non-default checks. Matches. |
| `AutoRecommendationEngine.swift` | 127 A, 165 P, 242 D, 261 P, 324 D, 528 A, 632 A | Codex planning fallback stays `.gpt56SolHigh` (130); API planning is `AIModel.gpt61SolHigh`; tradeoff copy is GPT-6.1; free-tier chat fallback stays `.gpt56SolMedium` (245); free-tier OpenAI chat is `gpt61Sol` (264, F7); Context Builder stays Sol Low with `.gpt56SolLow` fallback (329-330); upgrade hint keeps Luna High; recommended-raw fallbacks are Codex `.gpt56SolHigh` and API `gpt61SolHigh` (629, 633). Matches. |
| `RecommendationTypes.swift` | 340 D, 348/364 P, 388 A, 410/423/434 A | Luna High profile untouched; `bestPlanning` = `gpt-6.1-sol`; `bestInAppPlanningReview` = `codex_custom_gpt-6.1-sol-high` / `.gpt61SolHigh`; `bestContextBuilder` keeps `gpt-6-sol-low` and gains the baseline note and "follows the newest Sol" strength; copy has no Luna Low and no context-size claim; `versionCode` 202_609. Matches. |
| `APISettingsViewModel.swift` | 2002/2017 P; local row A | Three seeds replaced (1956, 1960, 1971); `modelSeedSettingsStore` injected; reset sites use `firstAutomaticallyEligibleModel` (2147, 2174); also `test_setAvailableModels` (F5). Matches. |
| `AIModel.swift` | every anchor in the complete hunk ledger | 15 direct, 6 Anthropic, and 6 OpenRouter cases, `ModelInfo`, `StaticIdentity`, and identity-switch entries match upstream line for line; all 21 `codexCli*` GPT-6 cases, definitions, efforts, and identities are absent (D). Priority insertions are in upstream order, with the four private `codexCustom` constants at 807-810 for the CLI entries (A). Responses classification (956) and direct effort mapping (1125) are present, without the CLI effort branches. Local hunk: `isEligibleForAutomaticSelection` (1091), `firstAutomaticallyEligibleModel` (1114), filter in `findBestAvailableModel` (1127). Matches. |
| `PromptViewModel.swift` | local A | `pickDiffCapableFallback` last resort (6538, ledgered) and `pickContextBuilderFallbackModel` (6576-6580, F4). |
| `AnthropicProvider.swift` | 104 A, 111/128 P, 269 A | Shared `makeMessageParameters` (215) used by both public paths; adaptive defaults 64,000 streaming and 16,000 non-streaming with an explicit cap kept; `thinking` and `temperature` omitted for the adaptive family; `testAPIKey` request unchanged. Legacy normalization extended (F3). |
| `OpenAIProvider.swift` | 88/127/746 P | Identical to upstream. The existing internal `resolvedResponseMaxTokens` and `buildForegroundResponseParameters` needed no visibility change. Matches. |
| `AzureOpenAIProvider.swift` | 515/535 P | Mapping and 128,000 classification identical to upstream. Local: `RequestRoute` / `requestRoute(for:)` (380), marker-stripped `azureCustom` name, configured-descriptor precedence (412). These are listed adaptations. |
| `CurrentModelCatalogTests.swift` | 0-170 A (not added) | All 8 upstream methods redistributed per the plan's destination table; the static-CLI, 1,050,000-context, and `extendedContext` expectations are declined. |
| Test and helper files | plan test table plus the listed helpers | `CodexModelSpecifierModelRefreshTests`, `AgentModelCatalogModelRefreshTests`, `AutoRecommendationEngineModelRefreshTests`, `ModelPickerStringOrderingTests`, `DirectModelCatalogRefreshTests`, `AnthropicProviderRequestPolicyTests`, `APISettingsModelSeedTests`, `CodexDiscoveryTestState.gpt61Models()`, `IsolatedAPISettingsFixture`; plus `AIModelPreferenceRegressionTests` (F5). |

## Identifier matrix

Test abbreviations, all in `Tests/RepoPromptTests` unless noted:

- **CMS**: `AI/CodexModelSpecifierModelRefreshTests`
- **AMC**: `AgentMode/AgentModelCatalogModelRefreshTests`
- **DMC**: `AI/DirectModelCatalogRefreshTests`
- **APR**: `AI/AnthropicProviderRequestPolicyTests`
- **ARE**: `AgentMode/AutoRecommendationEngineModelRefreshTests`
- **SEED**: `AgentMode/APISettingsModelSeedTests`
- **MPS**: `AI/ModelPickerStringOrderingTests`
- **BRG**: `AgentMode/ClaudeCompatible/ClaudeCompatiblePluginBridgeTests`
- **CRS**: provider-package `ClaudeCompatibleRuntimeSupportTests`
- **PREF**: `AI/AIModelPreferenceRegressionTests`
- **CDE**: `AI/CodexDiscoveredEffortTests`, pre-existing and family-agnostic

Codex dynamic representations: chat `AIModel.codexCustom(name: <id>)` (persisted `codex_custom_<id>`), Agent Mode option raw `<id>`. Both exist only after live discovery.

### 1. Upstream static Codex CLI variants (21) and their dynamic equivalents

The common proving tests apply to every row:

- Wire split without discovery: CMS `testGPT6FamiliesSplitEveryEffortWithoutDiscovery`.
- Option construction from discovery: CDE `testAdvertisedAstraEffortsProduceStandardAndFastWireParameters`, which is generic.
- No static enrollment: AMC `testStaticCodexListDoesNotAdmitGPT6` and DMC `testDynamicCodexPriorityHintsDoNotCreateAvailableModels`, which asserts that no `gpt-6.1` entry is in the static chat list.

Rows add only identifier-specific tests.

| Surface | Upstream raw | Distribution representation | Wire base | Effort | Default eligibility | Disposition | Proving test |
|---|---|---|---|---|---|---|---|
| Codex chat/Agent | `codex_cli_gpt-6.1-sol-low` | `codexCustom("gpt-6.1-sol-low")` / `gpt-6.1-sol-low` | `gpt-6.1-sol` | low | Context Builder when newest Sol; simple- and medium-diff hint | D static → A dynamic | ARE `testContextBuilderRecommendsSolLowAndKeepsProviderRanking`; AMC `testPartialGPT61CatalogDoesNotBackfillGPT61Efforts`; DMC `testDynamicCodexPriorityHintsDoNotCreateAvailableModels` |
| Codex chat/Agent | `codex_cli_gpt-6.1-sol-medium` | `codexCustom("gpt-6.1-sol-medium")` / `gpt-6.1-sol-medium` | `gpt-6.1-sol` | medium | Engineer and Design Codex fallback when advertised; diff hints | D → A | AMC `testRoleDefaultsPreferDiscoveredGPT6AtEachRolePosition`, `testPreferredRawAdmitsOnlyAdvertisedEffortsOfTheNewestFamily`; DMC `testPrioritySelectionPreservesRequestedEffort` |
| Codex chat/Agent | `codex_cli_gpt-6.1-sol-high` | `codexCustom("gpt-6.1-sol-high")` / `gpt-6.1-sol-high` | `gpt-6.1-sol` | high | Pair and Codex planning/chat recommendation when advertised; diff hints | D → A | AMC `testRoleDefaultsPreferDiscoveredGPT6AtEachRolePosition`; ARE `testRecommendedChatModelRawPrefersSuppliedOptionsThenPolicyFallbacks`, `testComputingRecommendationsDoesNotMutateSettings`; DMC `testPrioritySelectionPreservesRequestedEffort` |
| Codex chat/Agent | `codex_cli_gpt-6.1-sol-xhigh` | `codexCustom("gpt-6.1-sol-xhigh")` / `gpt-6.1-sol-xhigh` | `gpt-6.1-sol` | xhigh | High-diff hint only | D → A | DMC `testPrioritySelectionPreservesRequestedEffort` (withoutHigh case) |
| Codex chat/Agent | `codex_cli_gpt-6.1-sol-max` | `codexCustom("gpt-6.1-sol-max")` / `gpt-6.1-sol-max` | `gpt-6.1-sol` (exact advertised `-max` ID keeps itself) | max | None (manual) | D → A | CMS `testExactAdvertisedIdentifierOwnsItsWireIdentity`; AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6.1-sol-ultra` | `codexCustom("gpt-6.1-sol-ultra")` / `gpt-6.1-sol-ultra`, discovery only | `gpt-6.1-sol` when advertised; raw unresolved otherwise | ultra only when advertised | None (manual) | D → A (static Ultra declined) | CMS `testGPT6UltraIsNotBackfilled`; AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-astra-low` | `codexCustom("gpt-6-astra-low")` / `gpt-6-astra-low` | `gpt-6-astra` | low | None (manual) | D → A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-astra-medium` | `codexCustom("gpt-6-astra-medium")` / `gpt-6-astra-medium` | `gpt-6-astra` | medium | None | D → A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-astra-high` | `codexCustom("gpt-6-astra-high")` / `gpt-6-astra-high` | `gpt-6-astra` | high | None | D → A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding`; CDE |
| Codex chat/Agent | `codex_cli_gpt-6-astra-xhigh` | `codexCustom("gpt-6-astra-xhigh")` / `gpt-6-astra-xhigh` | `gpt-6-astra` | xhigh | None | D → A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-astra-max` | `codexCustom("gpt-6-astra-max")` / `gpt-6-astra-max` | `gpt-6-astra` | max | None | D → A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding`; CDE |
| Codex chat/Agent | (no upstream static) `gpt-6-astra-ultra` | `codexCustom("gpt-6-astra-ultra")`, discovery only; UI binding `.gpt6AstraMax` | `gpt-6-astra` when advertised | ultra, never downgraded | None | A | CMS `testGPT6UltraIsNotBackfilled`; AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` (label ends " Ultra", effort `ultra`) |
| Codex chat/Agent | `codex_cli_gpt-6-luna-low` | `codexCustom("gpt-6-luna-low")` / `gpt-6-luna-low` | `gpt-6-luna` | low | None (Explore stays High) | D → A | ARE `testBestPracticeCopyNeverRecommendsLunaLow`; AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-luna-medium` | `codexCustom("gpt-6-luna-medium")` / `gpt-6-luna-medium` | `gpt-6-luna` | medium | None | D → A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-luna-high` | `codexCustom("gpt-6-luna-high")` / `gpt-6-luna-high` | `gpt-6-luna` | high | Explore default when advertised | D → A | AMC `testRoleDefaultsPreferDiscoveredGPT6AtEachRolePosition`, `testRoleDefaultsFallBackWhenNewestFamilyLacksTheEffort` |
| Codex chat/Agent | `codex_cli_gpt-6-luna-xhigh` | `codexCustom("gpt-6-luna-xhigh")` / `gpt-6-luna-xhigh` | `gpt-6-luna` | xhigh | None | D → A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-luna-max` | `codexCustom("gpt-6-luna-max")` / `gpt-6-luna-max` | `gpt-6-luna` | max | None | D → A | CMS `testFastServiceTierStaysSeparateFromModelAndEffort` (fast-max); AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-sol-low` | `codexCustom("gpt-6-sol-low")` / `gpt-6-sol-low` | `gpt-6-sol` | low | Context Builder when GPT-6 is the newest Sol | D → A | ARE `testContextBuilderRecommendsSolLowAndKeepsProviderRanking` |
| Codex chat/Agent | `codex_cli_gpt-6-sol-medium` | `codexCustom("gpt-6-sol-medium")` / `gpt-6-sol-medium` | `gpt-6-sol` | medium | Engineer when GPT-6 is newest | D → A | AMC `testRoleDefaultsPreferDiscoveredGPT6AtEachRolePosition` |
| Codex chat/Agent | `codex_cli_gpt-6-sol-high` | `codexCustom("gpt-6-sol-high")` / `gpt-6-sol-high` | `gpt-6-sol` | high | Pair and planning when GPT-6 is newest | D → A | AMC `testRoleDefaultsPreferDiscoveredGPT6AtEachRolePosition`; ARE `testRecommendedChatModelRawPrefersSuppliedOptionsThenPolicyFallbacks` |
| Codex chat/Agent | `codex_cli_gpt-6-sol-xhigh` | `codexCustom("gpt-6-sol-xhigh")` / `gpt-6-sol-xhigh` | `gpt-6-sol` | xhigh | None | D → A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Codex chat/Agent | `codex_cli_gpt-6-sol-max` | `codexCustom("gpt-6-sol-max")` / `gpt-6-sol-max` | `gpt-6-sol` (exact advertised `-max` ID keeps itself) | max | None | D → A | CMS `testExactAdvertisedIdentifierOwnsItsWireIdentity` |

### 2. New `AgentModel` cases (13)

`AgentModel.swift` lines 29-39 and 109-110. The Codex cases stay out of `modelsForAgent(.codexExec)`;
proving test AMC `testStaticCodexListDoesNotAdmitGPT6`.

| Surface | Upstream raw | Distribution representation | Wire base | Effort | Default eligibility | Disposition | Proving test |
|---|---|---|---|---|---|---|---|
| Agent UI binding | `gpt-6.1-sol-low` | `.gpt61SolLow`, context `nil`, no tags | `gpt-6.1-sol` | low | Via discovery only | A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding`, `testGPT6MetadataAndDiscoveryTags` |
| Agent UI binding | `gpt-6.1-sol-medium` | `.gpt61SolMedium`; base, none, and minimal resolve here without rewriting the raw | `gpt-6.1-sol` | medium | Via discovery | A | Same two, plus `normalizePersistedSelection` keeps `gpt-6.1-sol` |
| Agent UI binding | `gpt-6.1-sol-high` | `.gpt61SolHigh`, tags `[.complex, .engineering, .pair]` (no extended context) | `gpt-6.1-sol` | high | Via discovery; `bestInAppPlanningReview.agentModel` | A | AMC `testGPT6MetadataAndDiscoveryTags`; ARE `testBestPracticeTableNamesTheDistributionDefaults` |
| Agent UI binding | `gpt-6.1-sol-xhigh` | `.gpt61SolXHigh` | `gpt-6.1-sol` | xhigh | Via discovery | A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Agent UI binding | `gpt-6.1-sol-max` | `.gpt61SolMax` | `gpt-6.1-sol` | max | Via discovery | A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` |
| Agent UI binding | `gpt-6.1-sol-ultra` | `.gpt61SolUltra`; resolves only when advertised | `gpt-6.1-sol` | ultra | Via discovery | A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding` (`nil` without discovery, `.gpt61SolUltra` with it) |
| Agent UI binding | `gpt-6-astra-low` | `.gpt6AstraLow`, context `nil`, no tags | `gpt-6-astra` | low | Via discovery | A | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding`, `testGPT6MetadataAndDiscoveryTags` |
| Agent UI binding | `gpt-6-astra-medium` | `.gpt6AstraMedium` | `gpt-6-astra` | medium | Via discovery | A | Same |
| Agent UI binding | `gpt-6-astra-high` | `.gpt6AstraHigh` | `gpt-6-astra` | high | Via discovery | A | Same |
| Agent UI binding | `gpt-6-astra-xhigh` | `.gpt6AstraXHigh` | `gpt-6-astra` | xhigh | Via discovery | A | Same |
| Agent UI binding | `gpt-6-astra-max` | `.gpt6AstraMax` (also the Ultra binding) | `gpt-6-astra` | max (Ultra raw keeps `ultra`) | Via discovery | A | Same |
| Claude Code (Agent) | `claude-mythos-5-1` | `.claudeMythos51` "Mythos 5.1 (Restricted)", 1M, no tags | `claude-mythos-5-1` | per suffix | Never automatic | P | BRG `testClaudeCodeCatalogExposesSonnet55AndRestrictedMythos51` |
| Claude Code (Agent) | `claude-sonnet-5-5` | `.claudeSonnet55` "Sonnet 5.5", 1M, tags `[.balanced, .engineering, .extendedContext]` | `claude-sonnet-5-5` | per suffix | Recommendation-tagged; not the provider default | P | BRG `testClaudeCodeCatalogExposesSonnet55AndRestrictedMythos51` |

### 3. Direct OpenAI variants (15) and generated Azure counterparts

Direct rows: provider `.openAI`, Responses API, `defaultReasoningEffort` equals the effort, 128,000
resolved cap with `max_output_tokens` omitted on the wire. Proving test: DMC
`testOpenAIRefreshVariantsRoundTripAndResolveWireEfforts`. It covers the raw round trip, the provider,
the display name, the Responses flag, the effort, the foreground request's `model` and
`reasoning.effort` for streaming and non-streaming requests, and the omitted cap. It also asserts
that `gpt-6.1-sol-medium`, `gpt-6.1-sol-ultra`, `gpt-6-astra-ultra`, `gpt-6-luna-max`, and
`gpt-6-sol-high` do not exist.

Azure rows: generated raw `azure_custom___azure_default__<raw>`, display `azure/<display>`, routed to
deployment `<wire base>` with the variant's effort. Proving test: DMC
`testAzureRefreshVariantsPreserveDeploymentAndEffort`. It covers generated entries, picker entries,
configured deployments named like variants, and a variant routed through the configured base
deployment. The Azure 128,000 cap is not asserted (F2).

| Surface | Upstream raw | Distribution representation | Wire base | Effort | Default eligibility | Disposition | Proving test |
|---|---|---|---|---|---|---|---|
| Direct OpenAI | `gpt-6.1-sol` | `AIModel.gpt61Sol` | `gpt-6.1-sol` | medium | Simple/medium/high diff and medium whole priority; free-tier chat rec (F7) | P | DMC OpenAI and priority tests (`testPrioritySelectionPreservesRequestedEffort`) |
| Direct OpenAI | `gpt-6.1-sol-low` | `.gpt61SolLow` | `gpt-6.1-sol` | low | Simple and medium diff priority | P | DMC OpenAI; `testPrioritySelectionPreservesRequestedEffort` |
| Direct OpenAI | `gpt-6.1-sol-high` | `.gpt61SolHigh` | `gpt-6.1-sol` | high | Diff priorities, high whole; OpenAI planning recommendation | P / A | DMC OpenAI; ARE `testOpenAIRecommendationUsesDirectGPT61SolHigh` |
| Direct OpenAI | `gpt-6.1-sol-xhigh` | `.gpt61SolXHigh` | `gpt-6.1-sol` | xhigh | None (generic unlisted fallback only) | P | DMC OpenAI |
| Direct OpenAI | `gpt-6.1-sol-max` | `.gpt61SolMax` | `gpt-6.1-sol` | max | None | P | DMC OpenAI |
| Direct OpenAI | `gpt-6-astra` | `.gpt6Astra` | `gpt-6-astra` | medium | None | P | DMC OpenAI |
| Direct OpenAI | `gpt-6-astra-low` | `.gpt6AstraLow` | `gpt-6-astra` | low | None | P | DMC OpenAI |
| Direct OpenAI | `gpt-6-astra-high` | `.gpt6AstraHigh` | `gpt-6-astra` | high | None | P | DMC OpenAI |
| Direct OpenAI | `gpt-6-astra-xhigh` | `.gpt6AstraXHigh` | `gpt-6-astra` | xhigh | None | P | DMC OpenAI |
| Direct OpenAI | `gpt-6-astra-max` | `.gpt6AstraMax` | `gpt-6-astra` | max | None | P | DMC OpenAI |
| Direct OpenAI | `gpt-6-luna` | `.gpt6Luna` | `gpt-6-luna` | medium | Whole priorities; empty-compose OpenAI seed | P | DMC OpenAI; SEED `testSuccessfulValidationSeedsAnEmptyComposeModel` |
| Direct OpenAI | `gpt-6-luna-low` | `.gpt6LunaLow` | `gpt-6-luna` | low | Simple whole priority | P | DMC OpenAI; `testPrioritySelectionPreservesRequestedEffort` |
| Direct OpenAI | `gpt-6-luna-high` | `.gpt6LunaHigh` | `gpt-6-luna` | high | None | P | DMC OpenAI |
| Direct OpenAI | `gpt-6-luna-xhigh` | `.gpt6LunaXHigh` | `gpt-6-luna` | xhigh | None | P | DMC OpenAI |
| Direct OpenAI | `gpt-6-sol` | `.gpt6Sol` (Medium-only pin) | `gpt-6-sol` | medium | None | P | DMC OpenAI |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6.1-sol` | deployment `gpt-6.1-sol` | medium | Not in priorities | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6.1-sol-low` | deployment `gpt-6.1-sol` | low | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6.1-sol-high` | deployment `gpt-6.1-sol` | high | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6.1-sol-xhigh` | deployment `gpt-6.1-sol` | xhigh | Same | P | DMC Azure (also the configured `prod-sol` case) |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6.1-sol-max` | deployment `gpt-6.1-sol` | max | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-astra` | deployment `gpt-6-astra` | medium | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-astra-low` | deployment `gpt-6-astra` | low | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-astra-high` | deployment `gpt-6-astra` | high | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-astra-xhigh` | deployment `gpt-6-astra` | xhigh | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-astra-max` | deployment `gpt-6-astra` | max | Same | P | DMC Azure (also the configured `gpt-6-astra-max` case) |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-luna` | deployment `gpt-6-luna` | medium | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-luna-low` | deployment `gpt-6-luna` | low | Same | P | DMC Azure (also the configured `gpt-6-luna-low` case) |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-luna-high` | deployment `gpt-6-luna` | high | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-luna-xhigh` | deployment `gpt-6-luna` | xhigh | Same | P | DMC Azure |
| Azure (generated) | n/a | `azure_custom___azure_default__gpt-6-sol` | deployment `gpt-6-sol` | medium | Same | P | DMC Azure |

### 4. Direct Anthropic entries (6)

Provider `.anthropic`; the wire model equals the raw. Request shape for every row: no `thinking`, no
`temperature` (even with an override), default caps of 64,000 streaming and 16,000 non-streaming,
explicit cap kept. Proving tests: DMC `testAnthropicAndOpenRouterRefreshRawsStayProviderSpecific`
and APR `testClaude5RequestsOmitManualThinkingAndSamplingKeys`, `testAdaptiveDefaultsAndExplicitCapsAreModeCorrect`.

| Surface | Upstream raw | Distribution representation | Wire base | Effort | Default eligibility | Disposition | Proving test |
|---|---|---|---|---|---|---|---|
| Direct Anthropic | `claude-sonnet-5-5` | `.claudeSonnet55` | `claude-sonnet-5-5` | model default (adaptive) | Simple/medium/high diff priority; empty-compose Anthropic seed | P | DMC, APR; DMC `testPrioritySelectionPreservesRequestedEffort`; SEED `testSuccessfulValidationSeedsAnEmptyComposeModel` |
| Direct Anthropic | `claude-sonnet-5` | `.claudeSonnet5` | `claude-sonnet-5` | adaptive | Generic fallback only | P | DMC, APR |
| Direct Anthropic | `claude-opus-5-5` | `.claudeOpus55` | `claude-opus-5-5` | adaptive | Generic fallback only | P | DMC, APR; DMC `testRestrictedMythosIsNeverAnAutomaticFallback` (chosen over Mythos) |
| Direct Anthropic | `claude-opus-5` | `.claudeOpus5` | `claude-opus-5` | adaptive | Generic fallback only | P | DMC, APR |
| Direct Anthropic | `claude-fable-5-1` | `.claudeFable51` | `claude-fable-5-1` | adaptive | Generic fallback only | P | DMC, APR |
| Direct Anthropic | `claude-mythos-5-1` | `.claudeMythos51` "Claude Mythos 5.1 (Restricted)" | `claude-mythos-5-1` | adaptive | **Never automatic** (priority, generic fallback, compose last resort, Context Builder fallback, key-removal reset); explicit pin kept | P + local A | DMC `testRestrictedMythosIsNeverAnAutomaticFallback`; PREF `testContextBuilderFallbackDoesNotCopyRestrictedComposePin`; APR (request shape) |

### 5. OpenRouter presets (6)

Provider `.openRouter`; the wire slug equals the raw (dotted). Proving test: DMC
`testAnthropicAndOpenRouterRefreshRawsStayProviderSpecific`, which also asserts no hyphenated
Anthropic slug and no Mythos preset.

| Surface | Upstream raw | Distribution representation | Wire base | Effort | Default eligibility | Disposition | Proving test |
|---|---|---|---|---|---|---|---|
| OpenRouter | `openai/gpt-6.1-sol` | `.openrouterGpt61Sol` | `openai/gpt-6.1-sol` | n/a | None | P | DMC |
| OpenRouter | `openai/gpt-6-astra` | `.openrouterGpt6Astra` | `openai/gpt-6-astra` | n/a | None | P | DMC |
| OpenRouter | `openai/gpt-6-luna` | `.openrouterGpt6Luna` | `openai/gpt-6-luna` | n/a | None | P | DMC |
| OpenRouter | `anthropic/claude-sonnet-5.5` | `.openrouterClaudeSonnet55` | `anthropic/claude-sonnet-5.5` | n/a | Diff priorities; empty-compose OpenRouter seed | P | DMC; DMC `testPrioritySelectionPreservesRequestedEffort`; SEED `testSuccessfulValidationSeedsAnEmptyComposeModel` |
| OpenRouter | `anthropic/claude-opus-5.5` | `.openrouterClaudeOpus55` | `anthropic/claude-opus-5.5` | n/a | None | P | DMC |
| OpenRouter | `anthropic/claude-fable-5.1` | `.openrouterClaudeFable51` | `anthropic/claude-fable-5.1` | n/a | None | P | DMC; DMC `testRestrictedMythosIsNeverAnAutomaticFallback` (eligible) |

### 6. Sonnet 5.5 and Mythos 5.1 across package, chat, and Agent Mode

Package records: `ClaudeCompatibleProviderPlugin.swift:274, 334`, `supportsXHigh: true`. Chat
definitions: `ClaudeCodeAIModelCatalog.swift:30, 41`. Adapter XHigh set:
`ClaudeCompatibleModelCatalogAdapter.swift:390-391`. The Claude Code runtime receives the base model
with the effort passed separately (`runtimeModelParam` strips `:<effort>`). Ultra is rejected on
every surface; the package default stays `opus`.

| Surface | Upstream raw | Distribution representation | Wire base | Effort | Default eligibility | Disposition | Proving test |
|---|---|---|---|---|---|---|---|
| Package base | `claude-sonnet-5-5` | static record "Sonnet 5.5" | `claude-sonnet-5-5` | — | Not provider default | P | CRS `testProviderCatalogDefaultsExposeStableRawValues` |
| Package / Agent / chat | `claude-sonnet-5-5:low` | Agent option `claude-sonnet-5-5:low`; chat `claudeCodeModel("claude-sonnet-5-5:low")` | `claude-sonnet-5-5` | low | Not default | P | CRS above; BRG `testClaudeCodeCatalogExposesSonnet55AndRestrictedMythos51`; MPS `testClaudeCodePickerExposesOpus55WithSupportedEfforts` |
| Package / Agent / chat | `claude-sonnet-5-5:medium` | as above, `:medium` | `claude-sonnet-5-5` | medium | Not default | P | CRS, BRG, MPS (same methods) |
| Package / Agent / chat | `claude-sonnet-5-5:high` | as above, `:high`; Agent resolves to `.claudeSonnet55` | `claude-sonnet-5-5` | high | Not default | P | CRS, BRG, MPS |
| Package / Agent / chat | `claude-sonnet-5-5:xhigh` | as above, `:xhigh`; adapter XHigh-eligible | `claude-sonnet-5-5` | xhigh | Not default | P | CRS, BRG (`isValid`), MPS |
| Package / Agent / chat | `claude-sonnet-5-5:max` | as above, `:max` | `claude-sonnet-5-5` | max | Not default | P | CRS (`runtimeModelParam("claude-sonnet-5-5:max")`), BRG, MPS |
| Package / Agent / chat | `claude-sonnet-5-5:ultra` | rejected | — | — | — | P (absence) | BRG (`isValid` false; `validatedModel` nil); CRS (no `:ultra` option) |
| Package base | `claude-mythos-5-1` | static record "Mythos 5.1 (Restricted)" | `claude-mythos-5-1` | — | Not provider default; no tags | P | CRS `testProviderCatalogDefaultsExposeStableRawValues`; BRG |
| Package / Agent / chat | `claude-mythos-5-1:low` | Agent option `claude-mythos-5-1:low`; chat `claudeCodeModel("claude-mythos-5-1:low")` | `claude-mythos-5-1` | low | Never automatic | P + local A | CRS, BRG, MPS; DMC `testRestrictedMythosIsNeverAnAutomaticFallback` (Claude Code specifiers) |
| Package / Agent / chat | `claude-mythos-5-1:medium` | as above, `:medium` | `claude-mythos-5-1` | medium | Never automatic | P + A | CRS, BRG, MPS |
| Package / Agent / chat | `claude-mythos-5-1:high` | as above, `:high`; Agent resolves to `.claudeMythos51`; chat label "Claude Code Mythos 5.1 (Restricted) High" | `claude-mythos-5-1` | high | Never automatic; explicit pin kept | P + A | BRG; MPS; DMC (`validatedModel` keeps the explicit selection); PREF (explicit Context Builder pin kept) |
| Package / Agent / chat | `claude-mythos-5-1:xhigh` | as above, `:xhigh`; adapter XHigh-eligible | `claude-mythos-5-1` | xhigh | Never automatic | P + A | CRS (`runtimeModelParam`), BRG, MPS |
| Package / Agent / chat | `claude-mythos-5-1:max` | as above, `:max` | `claude-mythos-5-1` | max | Never automatic | P + A | CRS, BRG, MPS; DMC; PREF (restricted compose pin not copied) |
| Package / Agent / chat | `claude-mythos-5-1:ultra` | rejected | — | — | — | P (absence) | BRG; CRS |

### 7. Changed recommendation and seed identities

| Surface | Upstream raw | Distribution representation | Wire base | Effort | Default eligibility | Disposition | Proving test |
|---|---|---|---|---|---|---|---|
| Chat rec, Codex option (planning) | fallback `codex_custom_gpt-6.1-sol-high` | `codex_custom_<newest Sol advertised at High>`, otherwise `codex_custom_gpt-5.6-sol-high` | discovered Sol or `gpt-5.6-sol` | high | Recommendation (Apply only) | A (hunks 127, 632) | ARE `testRecommendedChatModelRawPrefersSuppliedOptionsThenPolicyFallbacks` (4 discovery states), `testComputingRecommendationsDoesNotMutateSettings` |
| Chat rec, OpenAI option (planning) | `gpt-6.1-sol-high` (`AIModel.gpt61SolHigh`) | `gpt-6.1-sol-high`, label "GPT-6.1 Sol High" | `gpt-6.1-sol` | high | Recommendation | P (127, 165, 632) | ARE `testOpenAIRecommendationUsesDirectGPT61SolHigh`, `testRecommendedChatModelRawPrefersSuppliedOptionsThenPolicyFallbacks` |
| Free-tier chat rec, OpenAI | `gpt-6.1-sol` | `gpt-6.1-sol` "GPT-6.1 Sol via OpenAI API" | `gpt-6.1-sol` | medium | Unreachable (no caller) | P (261) | **None** (F7) |
| Free-tier chat rec, Codex | fallback `gpt-6.1-sol-medium` | newest Sol Medium, otherwise `gpt-5.6-sol-medium` | — | medium | Unreachable | D (242) | **None** (inert) |
| Context Builder rec | fallback `gpt-6-luna-low` | newest Sol Low, otherwise `.gpt56SolLow` | discovered Sol | low | Recommendation and startup restore when nothing is saved | D (324) | ARE `testContextBuilderRecommendsSolLowAndKeepsProviderRanking`, `testSavedRoleOverridesAndContextBuilderSelectionSurviveDiscoveryChanges` |
| Role defaults (Explore / Engineer / Pair / Design fallback) | Luna Low; 6.1 Sol Medium/High fallbacks | Luna High; newest Sol Medium/High at an advertised effort, otherwise the GPT-5.6 fallbacks | — | — | Unpinned roles only | D (1880) | AMC `testRoleDefaultsFallBackToGPT56BeforeDiscovery`, `testRoleDefaultsPreferDiscoveredGPT6AtEachRolePosition`, `testRoleDefaultsFallBackWhenNewestFamilyLacksTheEffort`; ARE `testComputingRecommendationsDoesNotMutateSettings` |
| Best Planning (export) | `gpt-6.1-sol` | `gpt-6.1-sol`, label "GPT-6.1 Sol" | `gpt-6.1-sol` | none | Display | P (348) | ARE `testBestPracticeTableNamesTheDistributionDefaults` |
| Best In-App Planning/Review | `codex_custom_gpt-6.1-sol-high` / `.gpt61SolHigh` | same | `gpt-6.1-sol` | high | Display; label feeds the upgrade hint | P (364) | ARE `testBestPracticeTableNamesTheDistributionDefaults`, `testOpenAIRecommendationUsesDirectGPT61SolHigh` (hint text) |
| Best Context Builder | `gpt-6-luna-low` | `gpt-6-sol-low` / `.gpt6SolLow` (baseline) | — | low | Display | A (388) | ARE `testBestPracticeTableNamesTheDistributionDefaults`, `testBestPracticeCopyNeverRecommendsLunaLow` |
| Best Agent | Luna Low profile | `gpt-6-luna-high` / `.gpt6LunaHigh` | — | high | Display | D (340) | ARE `testBestPracticeTableNamesTheDistributionDefaults` |
| Profile version | `202_609` | `202_609` | — | — | Mute/completion state | P (unchanged) | ARE `testBestPracticeTableNamesTheDistributionDefaults` |
| Codex diff priority hints | `.codexCliGpt61Sol{Medium,Low,High}` / `{High,Medium,Low}` / `{High,XHigh,Medium}` | private `codexCustom("gpt-6.1-sol-{low,medium,high,xhigh}")` (`AIModel.swift:807-810`) | `gpt-6.1-sol` | as named | Wins only when that exact option is advertised | A (753, 782, 811) | DMC `testDynamicCodexPriorityHintsDoNotCreateAvailableModels`, `testPrioritySelectionPreservesRequestedEffort` |
| Anthropic compose seed | `claude-sonnet-5-5` | `claude-sonnet-5-5` | `claude-sonnet-5-5` | adaptive | Empty compose only | P (2002) | SEED `testSuccessfulValidationSeedsAnEmptyComposeModel`, `testRejectedKeyOrFailedKeyStorageWritesNoSeed` |
| OpenAI compose seed | `gpt-6-luna` | `gpt-6-luna` | `gpt-6-luna` | medium | Empty compose only | P (2002) | SEED `testSuccessfulValidationSeedsAnEmptyComposeModel`, `testSuccessfulValidationKeepsASavedComposeModel` |
| OpenRouter compose seed | `anthropic/claude-sonnet-5.5` | `anthropic/claude-sonnet-5.5` | same | n/a | Empty compose only | P (2017) | SEED `testSuccessfulValidationSeedsAnEmptyComposeModel`, `testRejectedKeyOrFailedKeyStorageWritesNoSeed` |
| Seed under chat/Oracle sync | n/a | planning raw copied instead of seed | — | — | Empty compose, sync on, planning set | P (existing behavior) | **None** (F1) |
| Saved selections | n/a | exact raws kept (`gpt-6.1-sol-ultra`, `gpt-6-astra-ultra`, `openai_custom_reasoning_high__gpt-6-sol`, role overrides, Context Builder pin) | — | — | Never rewritten | Decided | AMC `testGPT6ResolverMapsEveryEffortToItsUIBinding`; DMC OpenAI test; ARE `testSavedRoleOverridesAndContextBuilderSelectionSurviveDiscoveryChanges` (with disk reload) |

## Not determined

- **Test results.** No test, build, or lint ran (out of scope). This audit confirms that the named
  methods exist and assert what is listed, not that they pass at `616d67fe`.
- **Manifest and legal payloads.** Their correctness against the official `rust-v0.159.0` artifacts
  was not re-derived. The audit confirms only that they are byte-identical to the upstream post-image
  and that `SHA256SUMS` verifies 13/13. The plan's live checks own official-artifact verification.
- **Live behavior.** Runtime discovery, approval behavior, and direct-API behavior were not checked.
  The plan's live checks own them.
- **Upstream PR 1136 boundary.** The check compared added lines against upstream PR 1136's own changed
  literals and a set of router and pricing patterns. It is not proof against a pricing literal
  phrased differently.
