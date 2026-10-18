# Investigation: Bundled vs local Codex app-server — should RepoPrompt support both?

> Investigation report, observed 2026-09-05 on a local checkout with bundled `codex-cli 0.149.0`. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/releasing.md](../releasing.md), Bundled Codex artifact.

## Summary
The regressions blamed on "bundling" (global `AGENTS.md`, skills, hooks, MCP servers) are caused by the app-private `CODEX_HOME` introduced in upstream PR 612, not by which binary runs; the existing external-binary override keeps the same isolated home, so a bundled/local toggle restores none of them. Model discovery is already dynamic (60-second `model/list` polling); the remaining new-model latency comes from the backend's client-version floor, the runtime's compiled fallback catalog, and RepoPrompt's own closed effort/family parsing, of which only the first two would move with a newer local binary. Recommendation: no toggle; make advertised model metadata round-trip without hand-registration, speed up certified pin rotation, and keep projecting `~/.codex` state per feature.

## Question under investigation
RepoPrompt CE previously launched whatever Codex app-server the user had installed locally. A later change bundled a pinned Codex app-server inside the RepoPrompt app. After bundling, several Codex-native behaviours stopped applying to RepoPrompt Codex agents (global `~/.codex/AGENTS.md`, skills, hooks, MCP servers, and possibly more). Some have since been re-plumbed (skills, MCP, repo-local hooks); others (global hooks, possibly others) have not.

A Discord discussion proposes a toggle: bundled vs local Codex app-server, motivated by dynamic model fetching so new model releases do not require a RepoPrompt release.

Questions:
1. Why was the app-server bundled? (PR/commit rationale)
2. What exactly broke when it was bundled, and why (mechanism)? Which items are fixed vs still open? Full inventory.
3. Where does the model list come from — the bundled binary, the app-server protocol, or remote? Would a local app-server actually give dynamic models?
4. Is a bundled/local toggle a good idea? What are the alternatives (e.g. `CODEX_HOME` passthrough, letting the bundled server read the real `~/.codex`, auto-updating the bundled binary, pinned-protocol + local-binary)?
5. Is MP's argument (below) solid, and where are its gaps?

## MP's position (paraphrased)
MP questioned whether RepoPrompt should support both a local and a bundled Codex app server. Bundling's main benefit was easier reproduction for maintainers and an end to questions about which Codex version a user runs, but it broke things nobody expected, chiefly `~/.codex/AGENTS.md` and skills for Codex agents in RepoPrompt. Supporting both runtimes would undo that benefit and enlarge what has to be maintained, while global hooks and MCP servers were still unsupported. MP was working on restoring MCP servers but would probably drop that and use a local app server if that option were added. Either approach was acceptable; the concern was long-term maintainability and feature parity across both paths.

## Symptoms
- After bundling, Codex RP agents stopped picking up `~/.codex/AGENTS.md`, `~/.codex/skills`, hooks, MCP servers.
- Fixes landed for: global skills (upstream PR 824), global instructions projection (upstream PR 906), project hook approval flow (upstream PR 678). Global hooks and global MCP servers reportedly still not supported.
- Model list appears frozen to what the bundled runtime knows; new model releases require a RepoPrompt release (upstream PR 851 "Enable Codex apps with runtime 0.149.0", upstream PR 748 "Bundle Codex 0.147.0").

## Initial hypotheses
- H1: Bundling introduced a *managed* `CODEX_HOME` (isolated from `~/.codex`) so the app-server does not read user config; each "broken" feature is a facet of that isolation and is being re-plumbed one file/feature at a time.
- H2: The model list is served by the app-server (`model/list`), whose catalog is compiled into the binary; a local newer binary would surface newer models. But the app-server protocol/schema is also pinned by RP's schema contract check, so a mismatched local version could break RP.
- H3: A toggle would double the compatibility matrix (RP pinned schema × arbitrary local versions) and re-introduce the reproduction problem bundling solved.

## Background / Prior Research

### Git archaeology (explore agent, 2026-09-05)

**Bundling landed 2026-07-22/23 in two deliberately split PRs: upstream PR 605 (packaging) and upstream PR 612 (runtime authority).** Stated rationale in upstream PR 612: *"PR2 bundled a pinned Codex runtime. This PR makes that runtime the application authority so user PATH drift, stale global CLIs, and mismatched config/state no longer silently influence RepoPrompt sessions. Explicit external overrides remain available for advanced testing but must satisfy the same app-server contract."* The same commit (`f6ab144a`) introduced the isolated `CODEX_HOME` / `CODEX_SQLITE_HOME` under `~/Library/Application Support/RepoPrompt CE/Codex/{Debug,Release}/`, "leaving `~/.codex` and official Codex App state untouched".

Precipitating failure class: upstream issue 471 (still open) — nvm-installed Codex not found because the non-interactive login shell skipped `~/.zshrc`; CE resolved a stale binary or nothing and hit API 400 "requires a newer version of Codex".

| Date | SHA | PR | Subject | Note |
|---|---|---|---|---|
| 2026-07-22 | `4fd888ed` | Upstream PR 605 | Bundle pinned Codex runtime artifact (0.144.6) | Packaging/verification only; explicitly does not switch launch |
| 2026-07-23 | `f6ab144a` | Upstream PR 612 | feat: make bundled Codex the runtime authority | Introduces isolated CODEX_HOME; no PATH fallthrough |
| 2026-07-23 | `6d1c50af` | Upstream PR 612 | fix: harden Codex runtime authority | Same runtime/env snapshot for app-server + exec |
| 2026-07-26 | `4981b8a5` | Upstream PR 633 | Automate guarded Codex runtime update candidates | Read-only evidence generator; no auto apply |
| 2026-07-26 | `3b8d3165` | Upstream PR 635 | Update bundled Codex to 0.145.0 | Establishes `minimumExternalVersion == bundledVersion` |
| 2026-07-27 | `2eb8b38a` | Upstream PR 647 | Fix bundled Codex JIT entitlements (fixes upstream issue 646) | Re-signing stripped V8 JIT entitlements |
| 2026-08-09 | `1c41f62c` | Upstream PR 748 | Bundle Codex 0.147.0 and fix exec permissions | 0.147.0 removed `codex exec --full-auto` |
| 2026-08-16 | `b6ca6278` | Upstream PR 824 | Expose global skills to Codex agents (fixes upstream issue 821) | Registers `~/.agents/skills` via `skills/extraRoots/set` |
| 2026-08-20 | `18318807` | Upstream PR 678 | Codex project hook approval flow (fixes upstream issue 665) | Hook approvals in `~/.codex` never carried over; hooks silently fail-open |
| 2026-08-22 | `44774ffa` | Upstream PR 851 | Enable Codex apps with runtime 0.149.0 | Pin bump to 0.149.0 |
| 2026-08-30 | `13e9be2d` | Upstream PR 906 | Project global instructions into managed state (fixes upstream issue 831) | One-way atomic copy of `~/.codex/AGENTS(.override).md` into managed home |

Not merged: upstream PR 837 (open) — broader "restore safe Codex hook compatibility with isolated state" bundle; upstream PRs 678 and 906 landed the hook and instructions pieces instead. Still open: upstream issue 830 — user `[mcp_servers.*]` from `~/.codex/config.toml` silently dropped.

**Where the pin lives:** `Vendor/Codex/manifest.json:3` (0.149.0), `Scripts/codex_runtime_artifact.py:31` (`SUPPORTED_VERSION`), `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/Shared/CodexRuntimeAuthority.swift:9-10` (`bundledVersion`, `minimumExternalVersion = bundledVersion`), `Scripts/Fixtures/codex-app-server-contract.json:3` (`minimumCodexVersion`, schema-drift gate floor), `Scripts/codex_vendor_guardrails.sh:51`. Download happens at packaging time only; the app never downloads Codex at runtime (`docs/releasing.md`). Pin history: 0.144.6 → 0.145.0 (upstream PR 635) → 0.147.0 (upstream PR 748) → 0.149.0 (upstream PR 851).

**Existing escape hatch:** `REPOPROMPT_CODEX_EXECUTABLE` (absolute path only, must be ≥ `bundledVersion`). Ordinary `PATH` lookup is never consulted.

**Key structural observation:** the user-visible regressions (global AGENTS.md, skills, hooks, MCP servers) all stem from the *isolated CODEX_HOME*, not from *which binary* runs. Swapping the binary while keeping the isolated home would not restore any of them.

### GitHub tracker inventory (explore agent, 2026-09-05)

Repo: `repoprompt/repoprompt-ce` (GitHub Discussions disabled; issues/PRs are the whole tracker). Maintainer rationale for the isolated home, verbatim from upstream PR 837: *"RepoPrompt CE intentionally runs bundled Codex with an app-managed `CODEX_HOME` so Agent Mode does not pollute or depend on the user's ordinary Codex sessions and mutable runtime state. That isolation also removed compatibility that users reasonably expect from Codex: repository hook approval/execution and global `AGENTS` instructions."*

| Upstream item | Type | State | Title / what it did | Codex feature |
|---|---|---|---|---|
| 605 | PR | merged | Bundle pinned Codex runtimes (0.144.6); does not switch launch | runtime packaging |
| 612 | PR | merged | Make bundled runtime authoritative; injects app-private `CODEX_HOME`/`CODEX_SQLITE_HOME` — **the regression source** | all `~/.codex` state |
| 665 | issue | closed | Agent Mode silently skips untrusted project hooks (security control failing open) | project hooks |
| 678 | PR | merged | Project hook approval flow (fixes upstream issue 665): `hooks/list`, approval card, `trusted_hash` via `config/batchWrite`, fail-closed | project hooks |
| 837 | PR | open, stale | Maintainer's competing hook + AGENTS projection + managed-home settings bundle; overlaps upstream PRs 678 and 906 | hooks, AGENTS.md, UX |
| 748 | PR | merged | Bundle 0.147.0; `--full-auto` removed → `--sandbox workspace-write` | runtime version |
| 821 / 824 | issue / PR | closed / merged | Global skills in `~/.agents/skills` invisible → fixed via `skills/extraRoots/set` | global skills |
| 830 | issue | **open, no PR** | User `[mcp_servers.*]` from `~/.codex/config.toml` silently absent | global MCP servers |
| 831 / 906 | issue / PR | closed / merged | Global `AGENTS.md` dropped → one-way atomic copy into managed home with ownership manifest | global AGENTS.md |
| 851 | PR | merged | Bundle 0.149.0; stop force-disabling Codex apps/plugins/MCP elicitation/tool suggestions | apps/plugins |
| 307 | issue | open | Settings: enable/disable discovered skills | skills management |
| 471 / 473 | issue / PR | open | Codex resolution misses nvm-installed CLI (pre-bundle PATH path; largely historical) | local CLI resolution |
| 479 / 490 | issue / PR | open | Managed login misreports OAuth state | auth |
| 691 | PR | merged | Opt-in Codex memories setting | config settings |
| 951 | PR | open | Add GPT-6 Astra to all Codex model pickers (hand-registration) | model list |
| 952 | PR | **closed, not merged** | Discover provider models from advertised capabilities (`model/list` → all catalogues) | model list (dynamic) |
| 953 | PR | open | Resolve advertised Codex Max/Ultra effort selections outside hardcoded families | model list |
| 781 | PR | open | Cache dynamic model records to prevent app hang | model list |
| 708 | issue | open | Track MCP 2026-07-28 protocol revision | MCP protocol |

**Still unsupported for bundled RP Codex agents:**
- Tracked, open, no fix in flight: global MCP servers (upstream issue 830); skill enable/disable (upstream issue 307); MCP 2026-07-28 (upstream issue 708).
- Explicitly excluded by design, no tracker: **global hooks** (upstream issue 665: *"under the isolated home they are invisible rather than untrusted, so no detection can surface them; fixing that would be an import/migration feature"*; upstream PR 837: *"No global hook bridge"*), the rest of `~/.codex/config.toml` (profiles, model providers, sandbox settings — upstream PR 837 *"No shared whole config or home"*), auth (`~/.codex/auth.json` not imported), sessions/history/SQLite.
- Named as follow-ups in upstream PR 748 without trackers: Agent Plugins, persistent conversation sections, paginated history, remote Code Mode, `--approve-for-me`.

**Now working (was broken):** global skills (upstream PR 824), global AGENTS.md (upstream PR 906), project hooks (upstream PR 678), Codex apps/plugins (upstream PR 851).

**Bundled-vs-local toggle:** no issue or PR proposes it. The only external-runtime path is `REPOPROMPT_CODEX_EXECUTABLE`, and per upstream issue 665 *"external overrides receive the same isolated state paths"* — so it does not restore any `~/.codex` feature.

### Upstream Codex app-server research (explore agent, 2026-09-05; openai/codex main ≈ rust-v0.153.4)

**Model list (`model/list`) is hybrid: compiled-in `models.json` + remote `GET {provider}/models?client_version=<ver>` + `$CODEX_HOME/models_cache.json` (TTL 300 s, keyed by client version).** Handler `codex-rs/app-server/src/models.rs` → `list_models(RefreshStrategy::OnlineIfUncached)`; background refresh every 4m30s (`models_refresh_worker.rs`). Merge rule (`models-manager/src/manager.rs` `apply_remote_models`): if remote list is non-empty, has ≥1 `List`-visibility model, **and** auth is a ChatGPT account → remote is the sole source of truth; otherwise the bundled catalog is the base with remote overlay by slug. `should_refresh_models()` only fetches when the endpoint uses the Codex backend or has command auth; API-key/third-party setups silently get the compiled-in list. `model_catalog_json` in config.toml swaps in a static catalog. **Strongly version-dependent:** the fallback catalog ships per build, the cache is discarded on `client_version` mismatch, and `client_version` is sent on the fetch (so the server can shape what an old client sees).

**What the app-server reads under `CODEX_HOME`** (layer precedence, top wins: MDM managed → `managed_config.toml` → SessionFlags (`-c` and protocol `config` overrides) → project `.codex/config.toml` (trusted only) → `$CODEX_HOME/<profile>.config.toml` → `$CODEX_HOME/config.toml` → enterprise bundle → `/etc/codex/config.toml`):
- `AGENTS.md`: `$CODEX_HOME/AGENTS.override.md` else `AGENTS.md`, then project chain root→cwd (`core/src/agents_md.rs`).
- skills: `.codex/skills` (repo), `$CODEX_HOME/skills` (deprecated), `~/.agents/skills`, `.agents/skills` in each dir root→cwd, `$CODEX_HOME/skills/.system` (`ext/skills/src/host_roots.rs`). Protocol: `skills/extraRoots/set` adds non-persisted roots process-wide.
- hooks: `<layer folder>/hooks.json` and inline `[hooks]` in that layer's config.toml (`hooks/src/engine/discovery.rs`). Global hooks live in `$CODEX_HOME`.
- `mcp_servers`: `[mcp_servers]` table in any config layer.
- `auth.json`, `rules/*.rules` (exec policy), `memories/`, `plugins/`, `sessions/`, `history.jsonl`, `models_cache.json`, sockets, etc.
- Per-thread overrides (`ThreadStartParams`): `model`, `cwd`, `approvalPolicy`, `sandbox`, `config: HashMap<String, JsonValue>` (arbitrary dotted-key overrides), `baseInstructions`, `developerInstructions`, `dynamicTools`, `selectedCapabilityRoots`, and more.

**Protocol stability:** no protocol version on the wire. `initialize` carries only `clientInfo` + `capabilities`; the response is `userAgent`, `codexHome`, platform. Stability is via capability gating (`experimentalApi`), not versioning. Measured churn: 100 commits to the v2 JSON schema between 2026-07-21 and 2026-09-04 (~2.2/day) with near-daily releases. Upstream guidance is regenerate types per binary (`codex app-server generate-json-schema`); there is no compatibility contract for old clients on newer servers and no runtime signal of drift.

**Running a host-owned binary while honoring `~/.codex`:** three composable mechanisms — `CODEX_HOME` env var (resolved once at startup, echoed back in `initialize`), global `-c key=value` config overrides (land in the SessionFlags layer above user config), and per-thread `thread/start.config`. A host can therefore point at the real `~/.codex` and still override specific keys. Caveat: SessionFlags sit below MDM/managed config.

**Other hosts:** the VS Code extension and desktop/mobile apps are first-party app-server clients. The first-party binary-sourcing pattern is a **Codex-managed install inside `CODEX_HOME`** (`$HOME/.codex/packages/standalone/current/codex`, installed by `install.sh`, with a detached updater loop), not a copy bundled into the host. The TypeScript SDK exposes `codexPathOverride`, `config`, and `env` (including `CODEX_HOME`) for exactly this seam.

## Investigator Findings

### Q1 — upstream PR 906 global `AGENTS.md` projection is not on this HEAD

The commit exists in the local object database and on remote refs, but it is not an ancestor of this checkout:

- `git log --all --oneline --grep='906' --grep='global instructions' --grep='AGENTS' -i` includes `13e9be2d fix(codex): project global instructions into managed state (#906)`.
- `git merge-base --is-ancestor 13e9be2d HEAD` exits `1`. `HEAD` is a local commit from 2026-08-29. The local branch is one commit ahead of and 46 commits behind `origin/bugfix/887-qualified-read-peer-stall`.
- `git branch -r --contains 13e9be2d` includes `origin/bugfix/887-qualified-read-peer-stall`, `origin/bugfix/881-large-export-watchdog`, `origin/bugfix/882-same-workspace-admission`, `upstream/main` (and `upstream/HEAD -> upstream/main`), plus multiple upstream feature/worktree refs. Thus the named remote tracking branch contains the fix even though the checked-out local HEAD does not.
- `git cat-file -e HEAD:Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/Shared/CodexGlobalInstructionsProjection.swift` fails because that path does not exist on HEAD. A HEAD-only Sources search for `AGENTS.override.md`, `AGENTS.md`, `instructions projection`, and `managed instructions` finds only unrelated project-instruction prompt text, not a projection implementation.

The remote commit is unambiguous about what is missing here. Its commit-relative `CodexGlobalInstructionsProjection.swift:72-76` names `AGENTS.override.md`, `AGENTS.md`, and `.repoprompt-agents-projection.json`; lines 79-114 read the ordinary and managed homes, compute actions, apply them, and commit the ownership manifest. Its commit-relative `CodexRuntimeAuthority.swift:36-48` calls that projection from `Runtime.prepareState()`. None of those changes is on this HEAD.

Remote state is also materially different: `origin` is `git@github.com:mplibunao/repoprompt-ce.git`, whose `origin/main` is stale at `56097581434cc730c137c925e5c0e3d37d585a18` (2026-07-17); `upstream` is `git@github.com:repoprompt/repoprompt-ce.git`, whose `upstream/main` is `2527a6e8d599a5dae3a36c5106cc34a9563639e5` (2026-09-04).

**Verdict — Refuted: the proposition that upstream PR 906 is present on HEAD is false; it exists on remote/upstream refs and in the object database, but not in this checkout.**

### Q2 — Dynamic discovery is real; static policy and effort decoding explain the release work

#### Why upstream PR 951 exists

Upstream PR 951 supplies no explicit rationale for hand-registration and has no comments or reviews. Its body says it adds GPT-6 Astra to the shared static catalogues, creates stable selections/display names, maps the base selection to Medium, and recognizes Max/Ultra suffixes. Therefore the exact authorial reason is **not documented**.

The code confirms that basic discovery did not need those constants. `CodexAppServerClient.listModels()` sends paginated `model/list` with no model allowlist (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexAppServerClient.swift:1401-1478`). `CodexModelPollingService` describes itself as the centralized dynamic-model owner and canonical registry writer (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/CodexModelPollingService.swift:10-27`), defaults to a 60-second interval (`:61-70`), and updates `AgentCodexModelRegistry` from every returned model (`:251-290`). The registry prefers live models, then cached dynamic records, and uses static options only when both are empty (`Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentCodexModelRegistry.swift:36-73`). The Chat/Oracle catalogue similarly uses cached dynamic models when present (`Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/CodexAIModelCatalog.swift:413-425`).

The concrete functional gap is Max/Ultra parsing. `CodexModelSpecifier` treats those suffixes as efforts only for hardcoded GPT-5.6 families (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppOnly/CodexModelSpecifier.swift:35-49,84-96`). Upstream PR 953, explicitly described as the focused follow-up to closed upstream PR 952, states the failure: an advertised unknown-family `gpt-future-ultra` is sent as the model name with no separate reasoning effort. This supports an inference—not an explicit upstream PR 951 rationale—that upstream PR 951’s load-bearing change is teaching the parser about Astra Max/Ultra; its other additions give Astra static/offline values, stable persisted enum cases, curated labels, and settings/MCP identities. Those constants do not establish runtime/account availability: upstream PR 953 explicitly says catalogue availability still depends on the selected runtime and account.

#### Why upstream PR 952 closed

Upstream PR 952 was self-closed by its author about 21 minutes after opening, with no closing comment and no maintainer request for changes. It was broad: 21 files spanning Codex, Claude Code, Anthropic API, xAI/Grok, picker publication, and a shared discovery cache. The only inline bot comment concerned intentional Anthropic variants and was rejected by the author; nothing ties it to the closure. Thirteen minutes later, upstream PR 953 opened as the “focused Codex parsing follow-up to closed upstream PR 952” and touches four files. The evidence supports **over-scope followed by a narrow recut** as an inference, but the closure reason is not verifiable as fact.

Upstream PR 781 is relevant because dynamic discovery has a cost: its body attributes an app hang to repeatedly decoding `CodexDynamicModelStore` from `UserDefaults` during picker sorting. Maintainer review blocks its proposed process-global cache because APIs accept arbitrary `UserDefaults` domains, so one suite could return another suite’s records. Dynamic discovery is therefore already real, but safe caching/invalidation remains a separate correctness and performance boundary.

#### Every hardcoded identifier/family list in the four requested files

1. `AgentCodexModelRegistry.swift`:
   - Recommended-backfill groups are `gpt-5.6-sol-low`/`gpt-5.6-low`, `gpt-5.6-sol-medium`/`gpt-5.6-medium`, `gpt-5.6-sol-high`/`gpt-5.6-high`, and `gpt-5.3-codex` (`:184-195`). If any group is absent, static options are merged into the advertised list (`:76-85,169-181`).
   - Equivalence special-cases bare/Medium `gpt-5.3-codex` and aliases `gpt-5.6` to `gpt-5.6-sol`; an unsuffixed 5.6 option is expanded only across Low/Medium/High equivalence keys (`:197-223`).
   - Fast synthesis itself has no model identifier allowlist; it delegates to the service-tier catalogue (`:88-118`).
2. `CodexAIModelCatalog.swift`:
   - Chat/Oracle backfill requires `gpt-5.6-sol-low`, `-medium`, `-high`, and either `gpt-5.3-codex` or `gpt-5.3-codex-medium` (`:441-452`).
   - Static `codex_cli_` values are converted to identities, and bare `gpt-5.6` is canonicalized to `gpt-5.6-sol` (`:454-475`).
   - The effort mapper is metadata-driven but accepts only values parsed by `CodexReasoningEffort` (`:203-233,341-383`).
3. `CodexServiceTierVariantCatalog.swift`:
   - It contains **no concrete model identifier list**. Fast is the only tier (`:3-5,60-65`); eligibility is generic for parseable `gpt-` versions newer than 5 or at least 5.3 (`:7-35`). A non-`gpt-` family or a new tier still needs code.
4. `CodexAgentModeCoordinator.swift:1826-2197`:
   - It contains **no model-family identifier list**. Collapse groups by parsed base/service tier and unions parsed plus advertised efforts (`:2006-2079`). Its only hardcoded display-token map is `gpt`/`codex`/`openai`/`max`, which is cosmetic (`:2108-2138`). Effort selection is metadata-driven with a Medium fallback (`:2140-2186`).

Two neighboring hardcoded policies are the real functional release gates: the closed effort vocabulary (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`) in `ReasoningEffort.swift:3-39`, and the Max/Ultra family switch in `CodexModelSpecifier.swift:84-96`. Static fallback identities remain in `AgentModel.swift:24-74,247-286` and `AIModel.swift:316-348`; role candidates still target GPT-5.6 Sol and older fallbacks in `AgentModelCatalog.swift:1843-1888`.

#### What still requires a RepoPrompt release

- **No release for the happy path:** a newly advertised model with an already-known effort vocabulary (and no Max/Ultra parsing ambiguity) flows dynamically into both picker families.
- **RepoPrompt code release:** a new family advertising Max/Ultra currently needs parser support; a new effort name needs the `CodexReasoningEffort` enum/parser; a non-`gpt-` family does not get synthesized Fast variants; a new service tier needs parsing/policy. Static offline choices, stable enum identities, curated labels/descriptions, backfill policy, and role defaults also require code changes if the product wants them.
- **Bundled-runtime release:** per the already-established upstream Codex research above, API-key/third-party configurations may not remote-refresh models, leaving the binary’s compiled catalogue as fallback. A new bundled binary is then required before its `model/list` can expose a model absent from 0.149.0. RepoPrompt itself merely consumes the app-server response.
- **Possible backend version floor:** upstream issue 471 proves that OpenAI has refused a genuinely old Codex client for a then-new model, but it does not prove that 0.149.0 is refused for Astra or any present model. That candidate remains model/version-specific evidence, addressed in Q3.

**Verdict — Confirmed with one unknown: discovery is dynamic, but effort parsing, static/offline policy, role defaults, and sometimes the bundled binary remain release-gated; upstream PR 952’s self-closure rationale is undocumented, with a narrow recut the strongest labeled inference.**

### Q3 — No evidence that bundled Codex 0.149.0 is refused a new model

The tracker contains one concrete version-refusal report: upstream issue 471 records HTTP 400 `invalid_request_error`, “The 'gpt-5.6-sol' model requires a newer version of Codex.” Its evidence says the affected stale app binary was 0.142.5 while the terminal binary was 0.144.1. That is direct evidence that a backend model can enforce a Codex client floor; it is **not evidence about 0.149.0**, and it predates the bundled-runtime authority.

Searches of the repo/tracker for `client_version`, `unsupported model`, `model not available`, and `requires a newer version` found no 0.149.0-specific refusal. The only tracker hit for the last phrase is upstream issue 471. The upstream fact that model refresh sends `client_version` shows the service can shape a catalogue by client, but treating that as a hard refusal would be inference.

The client does not implement a version-refusal classifier. It preserves JSON-RPC error code, message, and data (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexAppServerClient.swift:377-394`) and returns the server message to callers; only invalid-method/invalid-params errors for `initialize` and `thread/resume` receive an added request-shape explanation (`:110-123`). Decoded server errors are otherwise relayed as `ClientError.requestFailed` (`:1821-1853`). The one model-specific fallback is an exec-only GPT-5.3-to-5.2 retry keyed to `model_not_found`/404-style text (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/Shared/CodexProviderHelpers.swift:198-225`; notice in `CodexExecAgentProvider.swift:577-595`); it does not cover arbitrary new models or the upstream issue 471 phrase.

**Verdict — Unverifiable-here: old-client refusal is proven for 0.142.5 and GPT-5.6 Sol, but no repository or tracker evidence shows bundled 0.149.0 being refused any new model.**

### Q4 — User-scoped Codex state inventory on this checkout

All rows must be read through the shared state-path invariant: `CodexRuntimeAuthority.statePaths()` resolves to `~/Library/Application Support/RepoPrompt CE/Codex/{Debug|Release}/{home,sqlite}`, not `~/.codex` (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/Shared/CodexRuntimeAuthority.swift:209-224`). Therefore a native Codex feature that reads `$CODEX_HOME` sees the managed home unless CE explicitly bridges it. In the table, “explicitly not projected” means the absence is confirmed on this HEAD; it does not claim that every omission is a permanent product-policy decision.

| User state | Status on this HEAD | Concrete evidence |
|---|---|---|
| Global `AGENTS.override.md` / `AGENTS.md` | **Explicitly not projected** | Q1: the upstream PR 906 implementation and `prepareState()` call are absent from HEAD. |
| `~/.agents/skills` | **Projected for native Agent Mode app-server sessions** | `agentModeDefault` returns that global root (`CodexNativeSessionController.swift:696-743`); it is registered with `skills/extraRoots/set` before binding (`:1202-1209`, also `:1921-1928`). The path is constructed at `AgentSupportDirectoryCatalog.swift:29-40`. |
| `~/.codex/skills` | **Explicitly not projected** | The runtime home is isolated and there is no copy/symlink/import path on HEAD; only `~/.agents/skills` is passed as an extra root. |
| Project hooks | **Supported in place; trust is re-created in managed state** | CE calls `hooks/list` for the execution cwd (`CodexHookTrustService.swift:138-160`), limits approval to `source == "project"` (`CodexHookTrustModels.swift:191-196`), and writes `hooks.state` trusted hashes with `config/batchWrite` (`CodexHookTrustService.swift:42-108`). Existing global approvals are not imported. |
| Global hooks | **Explicitly not projected** | No global hook definition import exists; the approval model deliberately filters to project hooks (`CodexHookTrustModels.swift:191-196`). |
| User `[mcp_servers]` in `~/.codex/config.toml` | **Explicitly not projected** | `CodexIntegrationConfiguration.configDirectoryURL()` is the managed `statePaths().codexHome` and all reads target its `config.toml` (`CodexIntegrationConfiguration.swift:104-170`). CE authors its own RepoPrompt block there (`:1254-1265`), not the user’s ordinary config. |
| `~/.codex/prompts` | **Explicitly not projected** | CE’s Codex prompt installer uses managed-home `configDirectoryURL()/prompts` (`MCPIntegrationHelper.swift:946-950,994-1000,1112-1119`). `AgentSupportDirectoryCatalog` constructs the ordinary path (`:20-40`) but excludes it from the always-readable roots it returns (`:43-52`); no projection consumer was found. |
| `rules/*.rules` exec policy | **Explicitly not projected** | No importer/copy path exists on HEAD. The controller can display an exec-policy amendment proposed by the app-server, but that is runtime approval UI, not importing ordinary-home rules. |
| `auth.json` | **Explicitly not projected** | No Codex `auth.json` copy/read exists. The UI explicitly says managed Codex uses “a separate sign-in from ~/.codex” (`CLIProvidersSettingsView.swift:1559-1564`). |
| Profiles and other `config.toml` keys | **Explicitly not projected** | There is no ordinary-config import; config ownership is the managed URL at `CodexIntegrationConfiguration.swift:104-110`. Tests mentioning profiles exercise preservation inside the file being mutated, not a source-home bridge. |
| Memories | **Existing user memories are not projected; managed memories are opt-in** | Memory features and generation/use are false by default and are enabled only by CE policy (`CodexOverrides.swift:3-14,175-195`). Storage remains under managed `$CODEX_HOME`; nothing imports `~/.codex/memories`. |
| Sessions / `history.jsonl` | **Explicitly not projected** | Nothing imports ordinary sessions/history; all child processes receive managed `CODEX_HOME`, so newly created Codex state belongs to that home. CE may persist a rollout path in its own session record, which is not a wholesale history import. |

Bundled and external runtimes use identical state paths **by construction**. `resolve()` computes `let state = statePaths(...)` once before choosing a source (`CodexRuntimeAuthority.swift:226-243`); the bundled runtime receives `state` (`:307-313`) and `resolveExternalOverride` returns the supplied `statePaths` unchanged (`:317-352`). Both app-server and exec launch paths merge that runtime environment (`CodexAppServerClient.swift:527-534`; `CodexExecAgentProvider.swift:89-96,160-165`). Thus `REPOPROMPT_CODEX_EXECUTABLE` changes the binary, not the state authority.

Relevant tests in `Tests/RepoPromptTests/AI/CodexRuntimeAuthorityTests.swift` are:

- `testBundledRuntimeResolvesRequestedArchitectureAndOwnedState` (`:21-48`), which asserts managed paths, `CODEX_HOME`/`CODEX_SQLITE_HOME`, and `codexHome != ~/.codex`.
- `testExplicitExternalOverrideIsAbsoluteVersionGatedAndObservable` (`:103-168`) and `testOverrideEnvironmentIsTheOnlyFallbackWhenBundleIsMissing` (`:244-260`).
- `testCodexPreflightUsesCapturedLoginShellOverrideInsteadOfInheritedAppEnvironment` (`:262-304`), which proves an external runtime’s exec child receives its `runtime.statePaths` environment.

There is no single test that resolves both sources and asserts equality, so the parity proof is structural plus split coverage rather than one direct cross-source assertion.

**Verdict — Confirmed: on this HEAD only `~/.agents/skills` is bridged from global user state; project hooks work in place with managed trust, while the listed `~/.codex` state is not imported, and bundled/external binaries share the same isolated state paths.**

### Q5 — External overrides have unchecked schema drift, and this HEAD sends undeclared `thread/resume.path`

The schema gate is developer/CI validation, not runtime negotiation:

- The architecture document directs developers to `make codex-schema-check` / `make dev-codex-schema-check` and generates schemas with `codex app-server generate-json-schema --experimental` (`docs/architecture/codex-app-server-schema-gate.md:1-20`). It says CI pins exactly 0.149.0 while local validation accepts that version or newer (`:22-32`). CI installs `@openai/codex@0.149.0` and invokes the make target (`.github/workflows/ci.yml:41-50`).
- The Python entry point accepts a developer-selected `--codex`, checks only that it is at least the fixture floor, generates into a temporary directory, and compares that generated bundle with the checked-in bounded contract (`Scripts/check_codex_app_server_schema.py:118-150,887-966`). It does not run inside the shipped app.
- Runtime external selection checks path, executability, and `--version >= 0.149.0`, then accepts the runtime (`CodexRuntimeAuthority.swift:317-352`). No schema generation or comparison occurs. `CodexAppServerClient.RequestFailure` can append reactive guidance after `initialize`/`thread/resume` rejects `-32601`/`-32602` (`CodexAppServerClient.swift:110-123`), but that is not runtime schema validation. Arbitrary newer overrides therefore expand the compatibility matrix without a preflight contract check.

The claimed request/fixture mismatch is present:

- `CodexNativeSessionController.requestThreadBinding()` adds `params["path"] = rolloutPath` whenever a resumed `SessionRef` has a non-empty rollout path (`Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1713-1728`) and then sends `thread/resume` (`:1739-1752`).
- The fixture’s `thread/resume` entry lists `threadId`, approval fields, and sandbox as always sent, and only `config`, `cwd`, `model`, and `serviceTier` as optional; `path` is absent (`Scripts/Fixtures/codex-app-server-contract.json:308-323`).
- The checkout’s own test explicitly expects `params["path"] == "/tmp/existing-thread.jsonl"` (`Tests/RepoPromptTests/AgentMode/Codex/CodexNativeSessionControllerGoalConfigTests.swift:822-873`), despite the test name claiming schema-aligned requests omit undeclared fields.
- The architecture document says “thread-level requests no longer send undeclared `effort` or `path`” (`docs/architecture/codex-app-server-schema-gate.md:124-128`), so documentation/fixture and Swift behavior are inconsistent on this branch.

This also exposes a limitation of the gate: it verifies the hand-maintained compact fixture against upstream generated schemas, but does not derive actual outbound fields from Swift. The fixture can pass while source sends an omitted field, exactly as this checkout demonstrates.

**Verdict — Confirmed: schema checking is developer/CI-only with no runtime validation of an external override, and this HEAD sends `thread/resume.path` although its compact contract does not declare it.**

## Investigation Log

### Phase 1.5 — External facts (three explore agents)
**Hypothesis:** Bundling rationale and regression inventory live in git history and the tracker.
**Findings:** upstream PRs 605 and 612 (2026-07-22/23) bundled Codex and made it authoritative with an isolated `CODEX_HOME`; the tracker shows the fix chronology (upstream PR 824 skills, upstream PR 678 project hooks, upstream PR 906 global AGENTS.md) and the still-open upstream issue 830 (user MCP servers); global hooks excluded by design (upstream issue 665, upstream PR 837). Upstream Codex: `model/list` is compiled catalog + remote `/models?client_version=` + cache; no wire protocol version; schema churn ~2.2 commits/day.
**Conclusion:** Confirmed; recorded in Background / Prior Research.

### Phase 2 — Context builder over the Codex runtime/model/contract seams
**Hypothesis:** H1 (isolation is the cause), H2 (pickers static-only), H3 (schema pin blocks arbitrary versions).
**Findings:** H1 confirmed structurally (`CodexRuntimeAuthority.resolve()` computes `statePaths()` before choosing bundled vs external). H2 **refuted**: `CodexModelPollingService` polls `model/list` and feeds both pickers; static data is backfill/fallback only. H3 confirmed with nuance: the gate is build/CI-time only; runtime accepts any external ≥ 0.149.0 without schema validation.
**Conclusion:** Hypotheses revised; see Investigator Findings Q2/Q5.

### Phase 3 — Pair investigator (five questions)
See `## Investigator Findings`. Orchestrator spot-checks: `git merge-base --is-ancestor 13e9be2d HEAD` → exit 1 (upstream PR 906 not on this HEAD; present on `upstream/main` 2527a6e8 and on `origin/bugfix/887-qualified-read-peer-stall`); `CodexNativeSessionController.swift:1727` sends `params["path"]` and `codex-app-server-contract.json:310-322` omits it — **also true on `upstream/main`**; `CodexModelSpecifier.swift:84-96` restricts Max/Ultra parsing to hardcoded GPT-5.6 families; upstream `bundledVersion` is still 0.149.0.

### Phase 4 — Chat synthesis (architecture critique)
Position, stress-test of MP's argument, ranked alternatives and Discord reply; folded into the sections below.

## Root Cause / Analysis

### Two independent axes, conflated in the debate
1. **Executable provenance** — bundled package vs `REPOPROMPT_CODEX_EXECUTABLE`. Selected in `CodexRuntimeAuthority.resolve()` (`CodexRuntimeAuthority.swift:226-243`); external override must be absolute, executable, and ≥ `bundledVersion` (`:317-352`).
2. **State provenance** — always the managed `CODEX_HOME`/`CODEX_SQLITE_HOME` under `~/Library/Application Support/RepoPrompt CE/Codex/{Debug|Release}/` (`:209-224`), applied to both provenances by construction (`:307-313`, `:317-352`; test `testBundledRuntimeResolvesRequestedArchitectureAndOwnedState`).

Every lost `~/.codex` feature is a facet of axis 2. Native Codex reads AGENTS.md, hooks, `[mcp_servers]`, rules, auth, prompts, memories relative to `$CODEX_HOME` (upstream `agents_md.rs`, `hooks/engine/discovery.rs`, config loader). CE re-plumbs them one at a time: skills via `skills/extraRoots/set` (`CodexNativeSessionController.swift:1202-1209`), project hooks via `hooks/list` + `config/batchWrite` trust (`CodexHookTrustService.swift:42-160`, filtered to `source == "project"` at `CodexHookTrustModels.swift:191-196`), global AGENTS.md via `CodexGlobalInstructionsProjection` from `Runtime.prepareState()` (upstream/main only). Still not bridged anywhere: global hooks, user `[mcp_servers]` (upstream issue 830), `~/.codex/prompts`, rules, auth, profiles, memories, sessions.

### What actually gates a new model today (ChatGPT auth, bundled 0.149.0)
| Layer | Blocks? | Local newer binary fixes? |
|---|---|---|
| Codex compiled catalog (fallback when remote unavailable / API-key auth) | Sometimes | Usually |
| Remote `/models?client_version=0.149.0` shaping | Possibly | Possibly |
| Backend client floor at turn time (upstream issue 471 class: HTTP 400 "requires a newer version of Codex", proven for 0.142.5) | Possibly; no 0.149.0 evidence | Possibly |
| RepoPrompt closed effort vocabulary (`ReasoningEffort.swift`; unknown efforts dropped in `CodexDynamicModelStore.canonicalRecord()`) | **Yes** for new effort names | **No** |
| RepoPrompt Max/Ultra suffix parsing hardcoded to GPT-5.6 families (`CodexModelSpecifier.swift:84-96`; upstream PR 953) | **Yes** — sends `gpt-future-ultra` as model name, effort nil → 400 | **No** |
| Recommended backfill / role defaults pinned to gpt-5.6-sol / gpt-5.3-codex (`AgentCodexModelRegistry.swift:184-195`, `CodexAIModelCatalog.swift:441-452`, `AgentModelCatalog.swift:1843-1888`) | Not visibility; only defaults/curation | No |

"Every new model requires a RepoPrompt release" is false for a newly advertised family with known metadata, true for new effort vocabulary / parsing semantics / curated defaults, and sometimes true for the runtime itself.

### Why a toggle is the wrong instrument
- It changes only axis 1; restores no `~/.codex` feature (upstream issue 665: "external overrides receive the same isolated state paths").
- It reopens the upstream issue 471 support class (arbitrary local versions, install sources) that upstream PR 612 was created to close.
- Protocol risk: no wire versioning; schema bundle changes ~every other day; the gate (`check_codex_app_server_schema.py`, CI pins exactly 0.149.0) never runs against an override at runtime, and it compares a hand-maintained fixture rather than deriving outbound fields from Swift — the `thread/resume.path` mismatch shows it can pass while source sends an undeclared field.
- Bypasses the artifact/signing/entitlement pipeline (`Vendor/Codex/manifest.json`, `codex_runtime_artifact.py`, upstream PR 647 JIT entitlements).
- The "both paths need feature parity" cost MP cites is mostly not real (both provenances share the client, controller, managed home, and bridges), but the compatibility-matrix cost is real and larger than he states.

## Recommendations
1. **C — make advertised model metadata round-trip (highest value):** carry raw advertised effort strings in `CodexDynamicModelRecord` / `CodexDynamicModelMapper` instead of dropping unknowns via `CodexReasoningEffort`; derive model/effort from advertised metadata rather than family-specific suffix heuristics in `CodexModelSpecifier.swift:35-96`; make recommended backfill data-driven (`AgentCodexModelRegistry.swift:169-223`, `CodexAIModelCatalog.swift:441-475`); keep role defaults as preferences, not validity. Upstream PR 953 is the narrow first step. Load/canonicalize cache once at the registry boundary (per upstream PR 781's hang).
2. **B — faster certified pin rotation:** use `make codex-update-candidate` (upstream PR 633) + `codex_runtime_artifact.py` + schema gate on a shorter cadence; consider a runtime-only update channel later, but only for artifacts that passed the same verification — never "latest".
3. **D — continue per-feature projection of `~/.codex` state:** AGENTS.md (done upstream, upstream PR 906); user MCP servers (upstream issue 830: allowlisted merge into managed `config.toml` via `CodexIntegrationConfiguration` + `config/mcpServer/reload`); global hooks (explicit import + extend `CodexHookTrustService` trust model to a `global` source).
4. **F — diagnostics (low cost):** expose `CodexModelPollingService.refreshNow()`, show last refresh time, runtime provenance/version, and flag static backfill vs advertised rows so a stale picker is not misread as "bundling blocks discovery".
5. **Do not** ship a bundled/local toggle (A). Keep `REPOPROMPT_CODEX_EXECUTABLE` as a documented advanced escape hatch. Treat a shared-`~/.codex` mode (E) as a separate, high-risk state-ownership design, not a binary switch.

## Preventive Measures
- Make the schema gate derive outbound request fields from Swift (or add a test that diffs `requestThreadBinding()` params against the fixture) so undeclared fields like `thread/resume.path` cannot pass CI.
- File the `thread/resume.path` mismatch (present on this HEAD and on `upstream/main` 2527a6e8) as an issue.
- When discussing Codex regressions in the tracker or Discord, name the axis explicitly: "binary provenance" vs "state home"; most of this thread's confusion comes from conflating them.
- Pull `upstream/main` into working branches before reasoning about Codex behaviour; this checkout was 46 commits behind its own remote branch and lacked upstream PR 906.

## Addendum 2026-09-05 (after MP review) — live Astra evidence and corrected framing

**Empirical check of the client-version gate (same machine, same day):**

| Cache | client_version | fetched_at (UTC) | contains `gpt-6-astra` |
|---|---|---|---|
| `~/Library/Application Support/RepoPrompt CE/Codex/Release/home/models_cache.json` (bundled runtime) | 0.149.0 | 2026-09-05T02:59:00Z | **no** |
| `~/Library/Application Support/RepoPrompt CE/Codex/Debug/home/models_cache.json` (bundled runtime) | 0.149.0 | 2026-09-05T03:00:55Z | **no** |
| `~/.codex/models_cache.json` (user's local Codex) | 0.153.0 | 2026-09-05 03:01 UTC | **yes** |

Both lists were fetched from the backend within minutes of each other. The only variable is `client_version`. This confirms that OpenAI's `/models` endpoint shapes the catalog by client version: RepoPrompt's dynamic polling works, but the bundled 0.149.0 is simply not served the new model. A newer runtime is therefore a **necessary** condition for Astra to appear; the Discord thread's motivation is empirically correct on this point. The RepoPrompt-side parsing gates (effort vocabulary, Max/Ultra families) are an additional, independent gate that a newer runtime does not remove.

**`REPOPROMPT_CODEX_EXECUTABLE` is not user-facing.** There is no settings UI to set it; the only UI reference is an error string in `CLIProvidersSettingsView.swift:1725`. RepoPrompt captures a login-shell environment for Codex launches (`ProcessEnvironmentBuilder.swift:110-116`, `.loginShell` for `.codexAppServer`/`.codexPreflight`), so a variable exported from a login-shell rc file would be picked up by the GUI app, but this is undocumented outside investigation notes. Treat it as a developer escape hatch, not an existing second path.

**Corrected framing of the toggle.** The toggle users are asking for is "the pre-upstream PR 612 behaviour": local binary **and** the user's own `~/.codex`. This report's earlier analysis evaluated a binary-only toggle over the managed home, which is not what the thread wants. Under the correct framing MP's parity argument holds in full: bundled+isolated mode requires a bridge plus UI for every `~/.codex` feature (hooks approval UI upstream PR 678, AGENTS projection upstream PR 906, skills bridge upstream PR 824, MCP bridge for upstream issue 830 still to build), while local+shared mode needs none of them. Supporting both means carrying every bridge for bundled users while local users get the features for free, and re-accepting version drift for local users. The "isolated home vs bundling" distinction remains true mechanically but does not weaken MP's argument; it only clarifies which half of upstream PR 612 caused the breakage.

**Additional regression reported by MP (2026-09-05):** third-party tooling that reads `~/.codex` state broke. CodexBar (usage/cost/session stats) lost data once RP Codex sessions, transcripts, and logs moved into the private home. Unlike AGENTS.md, skills, hooks, or MCP, this class cannot be fixed by a per-feature bridge into the managed home; it only comes back by sharing the user's `~/.codex` (or by RP writing session state back into it). It is the strongest single argument that the isolated-home trade-off was under-costed at upstream PR 612 time.
