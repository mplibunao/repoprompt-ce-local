# OpenCode ACP effort capability gate (2026-09-21)

> Investigation report, observed 2026-09-21 on OpenCode `1.18.31+014614d` and `main` at `e24df046`. It records what was true then. Where it disagrees with a current document, the current document is right.

This is the blocking live ACP capability gate, the first step of the local OpenCode effort-levels plan. This report replaces any prior partial report for the same gate; no file existed at this path before this run (the cancelled provider-failing run left nothing under `docs/investigations/`).

## Verdict

**GATE PASSED.** Both required targets PASS. The optional GPT-5.6 Luna probe also PASSes.

| Target | Required | Verdict |
|---|---|---|
| `deepseek/deepseek-flash` | yes | **PASS** |
| `opencode-go/glm-5.3` (exact GLM-5.3 ID on the OpenCode Go provider) | yes | **PASS** |
| `opencode-go/gpt-5.6-luna` | no (additional probe) | **PASS** |

OpenCode `1.18.31+014614d` advertises and applies a non-default effort config over ACP for all three targets. Implementation may proceed on this evidence.

## Environment and evidence freeze

- Executable invoked: `~/.local/bin/opencode acp`, installed through home-manager from the nix store. `--version` reported `1.18.31+014614d` at probe time (matches, not assumed).
- Safe cwd: an empty disposable temporary directory created fresh for this run; no repo, no config. Ordinary user environment inherited; nothing dumped.
- Distribution head: `e24df046` (`main`, clean tree except known untracked investigation/`.worktrees` entries). Upstream reference clone `repoprompt-ce-upstream-readonly` at `6f0e849a` (the plan's recorded refresh; left untouched per this task's no-git-mutation constraint). Port refs verified readable: `80622198` (upstream PR 1009 squash) and `7b19f7dc` (upstream PR 960 merge) are commits in the clone. The capability marker replicated below was read from upstream `ACPAgentSessionController.swift:550-558`.
- Two pre-existing `opencode acp` processes (children of a live parent started before this run) were observed and left untouched; they are independent ACP sessions, not artifacts of this probe.
- No OpenCode config, credentials, or persistent settings were read or modified.

## Method

Single probe process driving `opencode acp` over stdio JSON-RPC (newline-delimited), one session for all targets:

1. `initialize` (id 1) with `protocolVersion: 1`, `clientCapabilities: {fs:{readTextFile:false,writeTextFile:false}, terminal:false, _meta:{parameterizedModelPicker:true}}` (exact merged-controller marker, upstream `ACPAgentSessionController.swift:557`).
2. `session/new` (id 2) with `{cwd, mcpServers: []}`; captured the new session's ID.
3. Per target: `session/set_config_option` on the model selector → validate snapshot → mutate effort via the effort selector → validate → re-select the same model → record effort readback (ids 3–11).

Probe assertions mirror the gate's validation steps: complete `configOptions` array, requested model as selector `currentValue`, exactly one usable select definition with `category == "thought_level"` or id `"effort"` (type `select`, non-empty `currentValue`, non-empty `options`), current ∈ choices, ≥2 choices, and post-mutation readback confirming both model and effort. The raw transcript (29 lines, 168 KiB) stayed in the temporary run folder and was not committed.

## Results

Selector wire identity (identical across all snapshots): model selector id `model` (category `model`, 102 advertised values, type `select`); effort selector id `effort`, category `thought_level`, display name "Effort", type `select`; one `mode` selector also present. Bootstrap (`session/new`) already advertised one effort selector for the bootstrap current model `deepseek/deepseek-v4-pro` with current `high`.

| Step | deepseek/deepseek-flash | opencode-go/glm-5.3 | opencode-go/gpt-5.6-luna |
|---|---|---|---|
| Advertised model value (exact) | `deepseek/deepseek-flash` | `opencode-go/glm-5.3` | `opencode-go/gpt-5.6-luna` |
| Effort choices advertised | `low, high, max, default` | `low, high, max, default` | `none, low, medium, high, xhigh, max, default` |
| Current after model RPC (req id) | `low` (3) | `low` (6) | `none` (9) |
| Usable effort selectors | exactly 1 | exactly 1 | exactly 1 |
| Mutated to (effort req id) | `high` (4) | `high` (7) | `high` (10) |
| Readback after mutation | model kept + effort `high` | model kept + effort `high` | model kept + effort `high` |
| Same-model re-select (req id) | `high` kept (5) | `high` kept (8) | `high` kept (11) |
| Verdict | **PASS** | **PASS** | **PASS** |

`initialize` response: `protocolVersion 1`, `authMethods: [opencode-login]`, `agentCapabilities`: `loadSession: true`, mcp http/sse, prompt embeddedContext/image, session close/fork/list/resume. The server never sent an `authenticate` request (existing credentials sufficed; as the gate specifies, the auth-method list alone was not treated as an auth requirement). No other server→client requests arrived. Server notifications observed: `session/update` (`config_option_update` after each model change; one `available_commands_update` after the first model RPC). Responses can interleave with notifications after the request is written, matching the controller's inbound-sequencing requirement.

## CLI corroboration

`opencode models --verbose` run in the same safe cwd:

| Model | CLI variants | ACP choices | Consistency |
|---|---|---|---|
| `deepseek/deepseek-flash` | `low, high, max` | `low, high, max, default` | consistent: ACP is CLI ∪ {`default`} |
| `opencode-go/glm-5.3` | `low, high, max` | `low, high, max, default` | consistent: same superset |
| `opencode-go/gpt-5.6-luna` | `none, low, medium, high, xhigh, max` | same + `default` | consistent: same superset |

No disagreement: every CLI-enabled variant appears in the ACP selector; ACP additionally synthesizes a `default` choice (OpenCode's "no explicit variant" sentinel). Discovery must treat `default` as a real advertised wire value, not a UI-only concept.

## Timings (wall-clock RTT)

| RPC | RTT |
|---|---|
| `initialize` | 426.3 ms |
| `session/new` | 246.4 ms |
| first model RPC (`deepseek/deepseek-flash`, id 3) | 13.0 ms |
| effort RPC (deepseek, id 4) | 0.8 ms |
| model / effort / re-select RPCs, GLM-5.3 (ids 6/7/8) | 1.3 / 1.1 / 5.9 ms |
| model / effort / re-select RPCs, Luna (ids 9/10/11) | 0.5 / 1.1 / 0.5 ms |

Full handshake (initialize + session/new + first model RPC) ≈ 0.69 s. For the plan's bounded discovery jobs: RPCs are single-digit milliseconds once bootstrapped; reusing the 30 s bootstrap timeout as the forced-model-RPC deadline is generously safe.

## Cleanup and hygiene

- Cleanup path: stdin close → process exited by itself, exit code 0, 18.9 ms, 0 stderr lines. No unsupported session-deletion method was invented; no SIGTERM/SIGKILL escalation was needed.
- Post-run `pgrep -f "opencode acp"` shows only the two pre-existing processes; the probe's process was reaped.
- Secret scan of all raw captures (`acp-transcript.jsonl`, `models-verbose.txt`, `acp-stderr.log`, `probe-summary.json`) for credential shapes (`sk-…`, `Bearer …`, 32+ hex, 40+ base64, api-key/token/authorization/password strings): no credential-shaped content. The only word-level hits are skill descriptions inside OpenCode's `available_commands_update` notification and the nix store path. The captures stayed in temporary files and were not committed.

## Findings downstream work items consume

1. **Same-model re-select keeps the mutated variant** (all three targets: re-selecting the already-current model left effort at `high`). The plan's open question about clearing effort in the composer on a live session therefore resolves to its second branch: the clear action applies the definition's default value through the normal application path when a live controller exists. The planned test `testComposerClearOnLiveSessionRestoresProviderDefault` should encode exactly that.
2. **A different-model switch resets effort to the new model's default** (`deepseek-v4-pro high` → `deepseek-flash low`; `glm-5.3` → `low`; `gpt-5.6-luna` → `none`). This grounds the plan's "forced model RPCs may reset provider configuration" risk precisely: forced selection of the same model is readback-neutral, while any different-model forced selection (e.g. disposable discovery sessions) resets that session's effort to the target model's default.
3. **The effort selector appears as soon as a model is current** (including at `session/new` for the bootstrap-current model), with id `effort`, category `thought_level`, and a `default` sentinel choice beyond the CLI variant set. Upstream PR 960 and 1009 parsing keys (`id`, `currentValue`, `options[].value/name`, `type: "select"`) match the wire exactly.
4. Bootstrap current model for this installation is `deepseek/deepseek-v4-pro` (from global config), effort current `high` at bootstrap.

## Artifacts

The raw transcript, a redacted machine-readable summary, the `opencode models --verbose` capture, the probe script, and two empty stderr logs stayed in a temporary folder and were not committed.
