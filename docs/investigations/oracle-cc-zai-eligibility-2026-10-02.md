# Investigation: Oracle eligibility for CC Zai GLM

> Investigation report, observed 2026-10-02 on `main` at `6ac4685a` and production build 46. It records what was true then. Where it disagrees with a current document, the current document is right.

## Summary

Oracle supports the CC Zai Claude Code route in current source. Selecting its Opus option uses the shared configured Opus-to-GLM mapping and Z.ai credential, but Oracle does not offer or explicitly propagate the High effort suffix available in Context Builder. Context Builder and its Astra Oracle question response have now completed after explicit source-egress approval. The approved Context Builder/Astra question, independent Pair verification, and final Astra synthesis completed successfully. A live GLM Oracle response remains untested.

## Scope and evidence boundary

- Read-only investigation; this report is the only intended checkout write. No source, credentials, defaults, app lifecycle, or active implementation changes.
- Distribution checkout: the main checkout, `main`, HEAD `6ac4685a1927b40f620f6a7f9fc0292dfcb2d4c1`. Existing untracked worktrees/investigation reports preserved.
- Production CE CLI is reachable. Native MCP `bind_context` was unavailable, so the CE CLI served as the transport.
- Own unfocused investigation tab: `<redacted>`, in the owner's existing multi-root workspace, which includes this distribution; all source investigation must scope to this root.
- The concurrent implementation is outside this investigation. No DeepPlan. Same-chat next-turn model switching already works and is not a requested fix.

## Background / Prior Research

The task provides prior source confirmation of OpenCode and direct API Oracle support. Verify current local source and distinguish it from installed-runtime evidence. No external lookup is necessary to answer local eligibility.

## Verification methods

1. Compare the installed model options and preset exposure with the source's Oracle eligibility rules.
2. Trace a CC Zai choice through AIModel conversion, headless provider creation, slot-to-model mapping, and CLI arguments.
3. Compare Context Builder and Oracle configuration paths to establish which configuration and credentials they share.
4. If the workflow permits and resources are handed off, run one Context Builder question and Oracle synthesis in an isolated tab. Do not change the default or claim a GLM invocation without GLM-specific runtime evidence. Result: the first request was rejected before start. After explicit approval, the single request completed in 440.4 seconds with a successful Astra question response.

## Runtime observations

- `oracle_utils op=models`: only `current_chat_model`, display `CLI·GPT-6 Astra High`, modes Chat/Plan/Review, MCP Oracle Model.
- Allowlisted model settings: `models.planning_model` and `models.preferred_compose_model` both `codex_custom_gpt-6-astra-high`; synchronization enabled.
- Live role catalog: Explore and Engineer `CC Zai glm-5.3 — Opus High`; Pair `Claude Code Opus Latest (1M) XHigh`; Design `Claude Code Fable 5 XHigh`.
- Installed production bundle metadata: `com.pvncher.repoprompt.ce`, version `1.4.0`, build `46`; CLI version `1.4.0`. Info.plist supplies no commit provenance, so this report distinguishes checkout source from installed observations.
- `app_settings op=options key=models.planning_model agent=claudeCodeGLM limit=200`: 95 static Claude Code candidates, no compatible-backend entries. This surface labels itself non-exhaustive and uses `AIModel.allModels()`, so absence there does not establish backend ineligibility. It is not the configured UI picker catalog.
- Own-context `app_settings op=get group=context_builder`: `codexExec` / `gpt-6.1-sol-medium`. This metadata is scoped to the newly created investigation context and does not establish which model ran the user's previous builder. The user's CC Zai observation is preserved as task input.
- The initial window-1 handoff ended with a pre-launch approval rejection and immediate slot release. Following explicit approval and parent authorization to use normal admission, one builder question ran successfully and released the slot at 13:41:43 UTC. No concurrent run was cancelled or displaced.

## Investigator Findings

Source references below are relative to `Sources/RepoPrompt/` unless they begin with `Packages/`.

### Eligibility and authority

`Features/Settings/ViewModels/APISettingsViewModel.swift:1846` adds normal Claude Code models when connected, then independently adds each active compatible backend's models. `:991` defines active as Claude CLI not known missing, backend enabled and valid, a stored/shared secret present, and configured mirror flag set. Native Claude subscription/login is not the compatible backend's availability gate.

`Features/Prompt/ViewModels/PromptViewModel.swift:6441` checks compatible Oracle models with that same `compatibleBackendIsActive` predicate. `Infrastructure/AI/Providers/AIProviderFactory.swift:82` supplies `ClaudeCodeProvider` for their `.claudeCode` provider type. Thus CC Zai is a first-class Oracle route; Agent Mode provider labels and Oracle model identifiers are different representations.

`Infrastructure/AI/ModelCatalog/Providers/ClaudeCodeAIModelCatalog.swift:153` generates the compatible Oracle choices. The Opus raw identifier is **`claude_code__compatible:glmzai:opus`**: prefix and serialization at `Infrastructure/AI/AIModel.swift:577`; backend alias at `ClaudeCodeAIModelCatalog.swift:437`. It is not an `agent_run` compound model ID or the role name `explore`.

### Launch mapping and shared configuration

`Infrastructure/AI/Providers/ClaudeCodeProvider.swift:241` detects the compatible descriptor and calls `ClaudeCodeLaunchEnvironmentResolver` with backend variant plus requested slot. It assigns `effectiveModel`, environment overrides, and removed keys to the headless request.

The core resolver in `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeLaunchEnvironmentResolver.swift:139` retrieves the shared Z.ai key internally and uses the same backend store. This investigation did not call its key accessors or inspect credential values.

`Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeCompatibleRuntimeSupport.swift:596` validates that backend, normalizes the requested slot, and resolves the mapped backend model. For Opus, the CLI receives **`--model opus`**; the environment contains the configured `ANTHROPIC_DEFAULT_OPUS_MODEL`, backend URL, and credential binding (`:324`, `:352`, `:648`). Therefore an Opus mapping to `glm-5.3` supplies that backend model without needing a direct `glm-5.3` Oracle catalog entry. The live role display supports that the installed role's Opus route is currently named `glm-5.3`; no raw backend settings file was read.

Oracle invokes Claude in print mode, uses an empty strict MCP configuration, and blocks built-in filesystem/process/agent tools (`ClaudeCodeProvider.swift:26`, `:56`, `:245`). It reasons over packaged context. Context Builder uses the separate discovery agent runtime (`Features/AgentMode/Runtime/Providers/AgentRuntimeProviderService.swift:248`) to discover/read files. Sharing the backend does not give Oracle the builder's discovery tools.

### Explicit effort limitation

The compatible Oracle catalog produces Haiku, Sonnet, Opus plus direct `glm-4.7`, `glm-5-turbo`, and `glm-5.1` choices. It does not produce effort variants (`ClaudeCodeAIModelCatalog.swift:153`; package `ClaudeCompatibleRuntimeSupport.swift:374`). The compatible descriptor recognizes exact slot names (`ClaudeCodeAIModelCatalog.swift:319`), so a raw identifier ending in `compatible:glmzai:opus:high` does not validate. A direct `compatible:glmzai:glm-5.3` is also outside the supported direct-selection list; the configured Opus mapping is the intended available path.

Oracle's compatible branch returns before setting `options.effortLevel` (`ClaudeCodeProvider.swift:245–258`). `ClaudeCLIOptions.additionalEnvironment` only writes `CLAUDE_CODE_EFFORT_LEVEL` when effort is present (`:24`). The builder's `ClaudeCodeAgentConfig` instead parses an effort-encoded model and keeps the explicit effort (`ClaudeCodeAgentConfig.swift:113–133`, `:169–171`), then merges effort environment overrides into the headless launch (`ClaudeCodeAgentProvider.swift:388`).

Confirmed limitation: Oracle cannot explicitly select or guarantee **Opus High** through its compatible model identifier. This does not prove the running Claude CLI would use a different effective effort: inherited CLI/environment defaults may independently be High. No CLI defaults or process environment were inspected, and no live GLM Oracle run was performed.

### Model selection and presets

The exact UI navigation is **Settings → Agent Mode → Agent Models → Oracle Model → CC Zai → the `glm-5.3 — Opus` mapped choice**, assuming the current configured Opus mapping remains `glm-5.3`. `SettingsView.swift:562`, `:602` own the navigation; `AgentModelsSettingsView.swift:353` owns the Oracle dropdown; `AIModelDropDown.swift:171`, `:228` render compatible backends as top-level menus and apply the selected raw identifier. The Oracle dropdown choice affects the configured Oracle model. Built-in Chat is currently synchronized with Oracle, so changing that default would also update Built-in Chat (`AgentModelsSettingsView.swift:740`). No such change was made.

To expose GLM for explicit per-call use while retaining Astra as the configured default, use **Settings → MCP Server → Model Presets**, or the **Oracle Model Presets** link at the bottom of Agent Models. Keep an Astra preset alongside a named GLM preset; in the GLM preset editor select the CC Zai entry for the Opus mapping, and enable the intended Chat/Plan/Review modes. `ModelPresetsSettingsView.swift:29`, `:116`; `ModelPresetsSheet.swift:340`, `:363`; `AgentModelsSettingsView.swift:727`. The existing **Use Oracle Model Presets for MCP** toggle must be enabled and presets must not be temporarily hidden. The preset picker uses mapped model labels without slot suffixes (`OptimizedModelPicker.swift:194–215`), so it may show only `glm-5.3`. Verify the saved preset row shows **CC Zai glm-5.3 — Opus**; repeated mapping values can make picker labels ambiguous. Setup remains a recommendation; no settings were changed.

After setup, `oracle_utils op=models` returns the preset names and IDs instead of `current_chat_model`. Supply the listed GLM preset name or ID as **`oracle_send`'s `model` parameter**. **`ask_oracle` rejects `model`** (`MCPOracleToolService.swift:119` versus `:270`). Retain the existing `chat_id` for continuation; same-chat next-turn switching is already working and requires no fix. With effective presets and no explicit choice, automatic selection uses the first available preset supporting the requested mode. Keeping the configured Astra default alone does not preserve automatic selection: retain an available Astra preset first for each intended mode if that automatic behavior should stay on Astra.

`OracleViewModel+MCP.swift:160–336` is strict: with presets disabled or effectively empty, only `current_chat_model` or the configured Oracle display name is accepted; with effective presets present, explicit requests resolve a preset. Arbitrary backend raw strings and role/agent IDs are not a shortcut around this policy. `MCPOracleToolService.swift:416–486` implements the installed models-list behavior. The observed one-model list means no effective presets were exposed; it does not distinguish zero presets from temporarily hidden presets.

### Other provider routes

Current source supports direct API providers and OpenCode through the same Oracle provider dispatch (`AIProviderFactory.swift:48–92`) and separate availability gates (`PromptViewModel.swift:6413–6452`). No live OpenCode or direct API Oracle request occurred in this investigation.

Direct **Z.ai** is separate from **CC Zai**: `AIProviderFactory.swift:80` creates `ZAIProvider` with its default **general API** endpoint, while coding-plan validation explicitly constructs a coding-plan endpoint (`ZAIProvider.swift:4–25`; `AIQueriesService.swift:730–750`). Therefore selecting direct Z.ai should not be presented as equivalent to the existing Claude-compatible coding-plan route. This is source evidence; subscription/billing eligibility was not independently tested.

### Pair verification

An independent read-only source pass at HEAD `6ac4685a1927b40f620f6a7f9fc0292dfcb2d4c1`. References are relative to `Sources/RepoPrompt/` unless they begin with `Sources/` or `Packages/`, and `Runtime*.swift` below means `Packages/RepoPromptAgentProviders/Sources/RepoPromptClaudeCompatibleProvider/ClaudeCompatibleRuntimeSupport.swift`. The only runtime evidence here is the tool list exposed to the Pair session; the pass made no Oracle, Context Builder, settings, or CLI call.

#### Builder Oracle claims

| Claim | Verdict | Source evidence |
| --- | --- | --- |
| Only `oracle_send` accepts `model`; `ask_oracle` rejects it | Confirmed | Allowlists at `Infrastructure/MCP/MCPOracleToolService.swift:120` and `:271`. Both tools then call the same `tool_chatSend` (`:248`, `:349`; `Infrastructure/MCP/ViewModels/MCPServerViewModel.swift:846–857`), which runs `selectModel` (`Features/Chat/ViewModels/Oracle/OracleViewModel+MCP.swift:1107`). |
| Effective presets replace `current_chat_model` | Confirmed | `oracle_utils op=models` lists every stored preset when presets are on and not hidden, and only `current_chat_model` otherwise (`MCPOracleToolService.swift:416–483`). With effective presets, an explicit `model` must resolve to a preset; the sentinel is rejected (`OracleViewModel+MCP.swift:313–333`). |
| Automatic selection uses the first available preset supporting the mode | Confirmed | `OracleViewModel+MCP.swift:304–350`. The configured Oracle model is read only when presets are off, empty, or hidden (`:194–213`, `:233–298`). |
| Discovery keeps an encoded effort but lacks the Agent Mode preference fallback | Confirmed | `discovery(...)` passes `effortLevel: nil` (`Infrastructure/AI/Providers/ClaudeCodeAgentConfig.swift:113–133`). The initializer keeps the model string's explicit effort (`:169–171`), and only `agentMode(...)` falls back to the stored preference (`:72–77`). The effort reaches the launch environment at `Infrastructure/AI/Providers/ClaudeCodeAgentProvider.swift:388–390`. |

#### Answers

**Selection paths.** All MCP and Context Builder Oracle traffic goes through one selector, `OracleViewModel+MCP.swift:164–366`:

- Presets off, on with none stored, or hidden: the configured Oracle model, resolved strictly (`Features/Prompt/ViewModels/PromptViewModel.swift:443–466`). An explicit `model` accepts only `current_chat_model` or that model's display name.
- Presets on and visible: a preset is the only selectable unit. `oracle_send` takes a preset UUID or name; without one, the first available preset supporting the mode wins.
- `ask_oracle` is always automatic.
- Context Builder's generated answers call the selector without a model (`Features/ContextBuilder/ViewModels/ContextBuilderAgentViewModel.swift:5020–5031`; `OracleViewModel+MCP.swift:370–386`). The session or workspace planning-model override applies only in the presets-off or empty cases; with effective presets, builder answers also go to the first available preset.
- CE CLI `chat`, `newchat`, `plan`, and `review` map to `oracle_send` and forward `--model` (`Sources/RepoPromptMCP/CommandRunner/MCPCommandParser.swift:393–394`, `:1152`, `:1186`, `:1224`).

**Opus mapping to `glm-5.3`.** Confirmed in source. The CC Zai Opus choice stores the slot `opus`, not a backend model (`Infrastructure/AI/ModelCatalog/Providers/ClaudeCodeAIModelCatalog.swift:151–171`, `:319–377`). At launch, `opus` resolves to the current Opus mapping (`Runtime*.swift:635–648`, `:675–688`), the CLI receives `--model opus`, and `ANTHROPIC_DEFAULT_OPUS_MODEL` carries the mapped value (`Runtime*.swift:357`; `Infrastructure/AI/Providers/ClaudeCodeProvider.swift:245–255`). `glm-5.3` is absent from both the direct-selectable and supported model lists (`Runtime*.swift:374–387`) and passes through as configured text, so a preset follows the Opus mapping at call time: changing the mapping changes the backend model of an existing preset and its label.

**Explicit High effort.** Not available to Oracle. The compatible branch returns at `ClaudeCodeProvider.swift:255`, before the effort assignment at `:259`. `CLAUDE_CODE_EFFORT_LEVEL` is written only from that field (`:24–29`), and no other source sets or removes it; the compatible launch removes only the unused Anthropic auth variable (`Runtime*.swift:330–333`). The Oracle CLI runs at whatever effort it inherits. The adapter restricts XHigh to GLM-5.2 variants, while its non-XHigh validation accepts other effort values (`ClaudeCompatibleModelCatalogAdapter.swift:195–217`, `:315–325`). This does not establish a universal High ceiling or backend acceptance of Max. The requested parity target remains the user's Opus High route.

#### Token and context limits

- Source has no context-window value for `glm-5.3`. The GLM table knows only `glm-5.2[1m]` at 1,000,000 tokens (`Runtime*.swift:500–503`), used for Agent Mode metadata and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (`:346–351`), never as an Oracle gate.
- The inspected Claude Code provider path ignores `maxTokens` and sends the prompt on stdin in one print-mode turn (`ClaudeCodeProvider.swift:142–170`); `AIModel.maxTokens` has no Claude Code entry (`Infrastructure/AI/AIModel.swift:2616–2635`). This establishes no model-specific limit in those locations, rather than proving the entire Oracle pipeline has no other size checks. Actual GLM packet acceptance remains untested.
- Unknown: the real `glm-5.3` window at Z.ai, how the Claude CLI budgets an `opus` alias pointed at it, and the size of the completed builder packet, whose token accounting was incomplete.

#### Selection validity

- **Preset names** allow letters, digits, `_`, and `-`, up to 30 characters, starting alphanumeric. Other input is rewritten on save (`Infrastructure/AI/Models/ModelPreset.swift:79–143`); the editor previews the saved form (`Features/Settings/Views/ModelPresetsSheet.swift:310–333`). `glm-5.3 Opus` would save as `glm-5_3_Opus`.
- **Name lookup is fuzzy**: UUID, case-insensitive name, prefix, substring, Dice similarity of at least 0.6, then Levenshtein similarity of at least 0.8 (`OracleViewModel+MCP.swift:413–439`; `ModelPreset.swift:159–214`). A short or misspelled value can select a different preset. Pass the UUID.
- **Order is creation order.** Presets append (`ModelPreset.swift:366–370`), and `movePresets` (`:396–400`) has no caller in app source. Keeping Astra automatic requires creating its preset before the GLM preset, or deleting and recreating them.
- **Availability**: automatic selection skips a preset whose backend is inactive, and a named request for it fails (`OracleViewModel+MCP.swift:304–311`, `:318–323`; gate at `PromptViewModel.swift:6440–6444`). `oracle_utils op=models` still lists it (`MCPOracleToolService.swift:425–442`).
- **Silent model substitution**: the compatible ID parses only while its backend descriptor resolves for the current model behavior (`ClaudeCodeAIModelCatalog.swift:72–76`, `:319–377`). If CC Zai switched to no-model behavior, a stored `…:opus` preset would fail to parse, and `ModelPreset.model` falls back to `.claude4Sonnet`, an Anthropic API model (`ModelPreset.swift:24–26`). This is unlikely under the current slot-mapped configuration.
- **Hidden presets**: Apply Recommended Setup with preset exposure sets the hidden flag (`Features/AgentMode/Recommendations/AutoRecommendationEngine.swift:714–728`). Hidden presets count as none (`OracleViewModel+MCP.swift:217–221`), so automatic selection returns to the configured Oracle model and a named GLM preset is rejected. MCP settings offers **Show presets** (`Features/Settings/Views/MCPSettingsView.swift:309–352`).
- **Observed Pair tool exposure**: this Pair session exposed `ask_oracle` and not `oracle_send`, so that tool offers automatic selection rather than a per-call model parameter. This observation does not establish the tool exposure of every Agent Mode client. The broader exposure policy was not traced beyond the capability split at `Sources/RepoPromptDomainRuntime/MCPDomainToolCatalog.swift:272–273`; the user's working same-chat switching remains outside the requested investigation.

#### Corrections to earlier findings

- The explicit-effort retention cited as `ClaudeCodeAgentConfig.swift:157` is at `:169–171`; the `discovery` factory is `:113–133`.
- Keeping an Astra preset first depends on creation order, and that order also governs Context Builder's generated answers, not only MCP Oracle calls.
- Supply the GLM preset's ID rather than its name, because name lookup is fuzzy.
- Line drift without content change: the `ask_oracle` allowlist is `MCPOracleToolService.swift:120`, `oracle_send` is `:271`, and the preset-aware selector is `OracleViewModel+MCP.swift:164–366`.
- Confirmed: the preset editor's CC Zai menu (`Features/Settings/Views/OptimizedModelPicker.swift:108–148`, fed by `Features/Settings/ViewModels/APISettingsViewModel.swift:1846–1852`) and the active-backend gate (`:991–998`). The Oracle dropdown and Built-in Chat sync appear at `Features/Settings/Views/AgentModelsSettingsView.swift:356` and `:741–743`. Not re-verified: Settings navigation (`SettingsView.swift:562`, `:602`) and the direct Z.ai endpoint claims.

#### Suggested selection instructions

These change settings and remain recommendations.

1. In **Settings → MCP Server → Oracle Model Presets**, turn on **Use Oracle Model Presets for MCP**. If **Presets hidden by Setup Wizard** appears, choose **Show presets**.
2. Choose **Manage** and add the Astra preset first, for example `gpt6-astra-high`, with Chat, Plan, and Review enabled.
3. Add `zai-glm-opus` with the CC Zai Opus-mapped choice and intended modes. The picker may display only `glm-5.3`; verify the saved preset row shows **CC Zai glm-5.3 — Opus**. Put `glm-5.3` in the description because the name cannot contain a period.
4. Run `oracle_utils op=models` and copy the GLM preset UUID.
5. Call `oracle_send` with `model` set to that UUID; pass the existing `chat_id` to continue a chat.
6. After Apply Recommended Setup with preset exposure, check preset visibility and choose **Show presets** if they became hidden.
7. Treat Opus High parity as unverified: the Oracle request carries no effort setting.

### Final Oracle synthesis

The final `oracle_send` continuation in the investigation's Oracle chat completed by **14:01:01 UTC** on 2026-10-02. Immediately before dispatch, `oracle_utils op=models` exposed only `current_chat_model: CLI·GPT-6 Astra High`; the call explicitly selected that sentinel. The final synthesis confirmed eligibility, slot mapping, strict preset selection, and the explicit-effort gap. It corrected the preset-picker label and the overbroad claim that High is a universal builder ceiling; both corrections were spot-checked against source and folded into this report.

The final source conclusion is **CC Zai Opus is an eligible Oracle route, with its backend model resolved from the shared mapping at launch**. The installed role label supports the current GLM-5.3 mapping but no raw configuration or credential was inspected. The current production Oracle remains Astra with no effective exposed GLM preset. Therefore this investigation confirms the available source path without claiming installed GLM execution, inherited effort, or context-window acceptance.

For explicit selection after separately choosing to configure a preset, use the listed UUID:

```json
{
  "message": "Your question",
  "mode": "chat",
  "model": "<GLM preset UUID>",
  "chat_id": "<existing chat ID>"
}
```

Send that object to `oracle_send`. The CE CLI `chat` command also forwards `--model` and `--chat-id`. `ask_oracle` remains automatic and has no model argument. No GLM runtime bug was reproduced, and no issue or implementation was created.

## Conclusions and recommendations

1. Use the existing CC Zai Opus-mapped Oracle choice when the goal is the same GLM backend. No implementation is needed to establish source eligibility.
2. Prefer a named GLM Oracle preset alongside Astra for explicit model selection. Do not change defaults merely to test eligibility.
3. Treat explicit compatible Oracle effort selection as a verified source capability gap, not a reproduced GLM runtime failure. No issue was created. An enhancement would belong to the compatible Oracle catalog/descriptor and `ClaudeCodeProvider.makeOptions`, with live validation before declaring full Opus High parity.
4. Do not pursue same-chat model-switching changes; that behavior is already working and outside scope.

## Workflow approval and execution

The first installed `/rp-investigate` Phase 2 Context Builder request was rejected by automatic approval review before launch because repository-source egress lacked explicit payload and destination approval. The shared slot was released immediately. The user then accepted the three-destination question (Context Builder GPT-6.1 Sol Medium, Oracle GPT-6 Astra High, Pair Claude Code Opus Latest (1M) XHigh) and explicitly repeated approval for selected distribution source through Context Builder and Oracle, with production settings unchanged.

Parent/task status messaging returned `Codex app-server is not available` or `An earlier turn submission is not yet confirmed`. The parent subsequently authorized proceeding through normal admission rather than waiting indefinitely, without cancelling or displacing another run. The source admission guard (`ContextBuilderAgentViewModel.swift:4552`) atomically rejects a second active run in the window. The single approved investigation request was admitted in the original context, observed running by **13:34:37 UTC**, and observed complete at **13:41:43 UTC** on 2026-10-02. CLI elapsed time was **440.4 seconds**. Completion released the shared slot; status was stated plainly in task commentary and attempted through parent messaging.

The completed builder selected 32 scoped distribution files (21 full, 11 slices) and produced the investigation's Oracle chat. Token accounting was reported incomplete/pending; its displayed count is not treated as final authority. The generated question response confirmed backend support and explicit-effort limitations, and corrected the `ask_oracle` versus `oracle_send` parameter distinction. It also distinguished discovery's explicit encoded effort from Agent Mode's preference fallback. Pair verification completed in session `<redacted>`, run `<redacted>`, on `Claude Code opus[1m]:xhigh`. Its source checks are recorded above. The parent selection was then expanded additively with Pair-referenced preset, parser, exposure, and token-metadata source; no selection was cleared or replaced. The final Astra synthesis completed in the same Oracle chat, as recorded above.

Installed CLI parameter probes were read-only and stopped before any model request: `ask_oracle` reported that it is available only during discovery or Agent Mode, while `oracle_send` rejected an intentionally unsupported parameter and returned its allowlist including `model`. Source, rather than that first probe, establishes the `ask_oracle` parameter restriction.

There has been no live GLM Oracle test, production restart, settings/credential change, source edit, build/test job, or new workspace/worktree. The approved Astra responses validate the investigation transport and synthesis. They do not validate a GLM Oracle invocation.

## Maintainer-guidance check

- **User impact and invariant:** expose a supported Oracle backend choice, preserve current settings and the active implementation.
- **Confidence:** source eligibility and explicit-effort limitation confirmed; GLM Oracle runtime success/effective effort untested.
- **Authority:** configured UI model catalog, Oracle preset selector, ClaudeCodeProvider, shared backend store/resolver; static options are non-exhaustive.
- **State safety:** no credential reads, settings edits, lifecycle action, or active context mutation. Only the investigation report and investigation-owned contexts were created.
- **Scale and observability:** scoped source reads, one pre-launch rejection, one successful approved builder run, one completed Pair pass, and a final approved Astra synthesis. The shared builder slot was released on completion.
- **Recommended scope:** existing model/preset selection; optional separately authorized effort enhancement only if full explicit parity is wanted.
- **Validation boundary:** installed catalog/settings metadata, targeted RPC validation, local source cross-check, completed builder/Astra question, and independent Pair verification. Live GLM Oracle behavior and effective effort remain untested.

## Report verification

The checkout HEAD remained `6ac4685a1927b40f620f6a7f9fc0292dfcb2d4c1`. Tracked-file status and `git diff --check` were clean; only this new untracked investigation report was intentionally written in the checkout. Source references were checked through scoped CE file reads. No build or test job was needed for this report.

Vale ran on the final report and returned 133 errors, 89 warnings, and 120 suggestions. Findings include product names/acronyms, the technical term `backend`, and source-oriented prose. Treating those as review input, this report keeps the exact product vocabulary and evidence identifiers instead of applying blanket prose rewrites; Vale is not claimed as passing.
