# Investigation: RepoPrompt Codex Agent Hang

> Investigation report, observed 2026-07-08 with Codex CLI 0.143.0. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/architecture/codex-app-server-schema-gate.md](../architecture/codex-app-server-schema-gate.md), Bounded contract.

## Summary
RepoPrompt CE is the failing layer for the observed hang. Basic Codex CLI and direct Codex app-server calls work on this machine, but RepoPrompt's Codex integration has stale app-server protocol assumptions that can leave Codex turns active forever in the UI.

## Symptoms
- RepoPrompt CE chats using Codex models remain on `Thinking...` without producing an answer.
- RepoPrompt workflows that dispatch RepoPrompt agents, including investigate and deep-plan workflows, hang when the selected agent role resolves to a Codex model.
- The visible RepoPrompt CE UI showed stuck Codex CLI `GPT-5.5` sessions in both a work-repository workspace and the owner's multi-root workspace on July 8, 2026.

## Background / Prior Research
- RepoPrompt CE MCP remained responsive while the visible Codex chat was stuck. `bind_context`, `app_settings`, and `agent_manage` returned normally.
- RepoPrompt CE model settings showed `models.preferred_compose_model` and `models.planning_model` set to `codex_custom_gpt-5.5-high`.
- RepoPrompt CE role labels resolved `explore`, `engineer`, and `pair` to Codex CLI GPT-5.5 variants, while `design` resolved to Claude Code Fable 5 High.
- Direct Codex CLI outside RepoPrompt completed a `gpt-5.5` smoke prompt successfully with Codex CLI 0.143.0, so basic Codex CLI authentication and GPT-5.5 availability worked outside RepoPrompt.
- Direct `codex app-server` also completed a GPT-5.5 turn when driven with the current generated TypeScript protocol shape.
- The current generated Codex app-server `UserInput` type uses `text_elements`, while RepoPrompt's `turnInput` builder sends `textElements`.

## Investigator Findings
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1317` sends `turn/start` without a timeout because model reasoning can legitimately run for a long time. That makes terminal-event parsing correctness critical: a missed completion event looks like an indefinite hang.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1593` builds text input entries with `type` and `text`, then `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:1596` serializes `textElements`. The generated Codex app-server schema from `codex app-server generate-ts` expects `text_elements`.
- A direct app-server probe with RepoPrompt's camel-case input shape was rejected by Codex with `Invalid request: missing field type`. The same probe completed when using the generated shape with `text_elements`.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:2364` treats `turn/completed` and `codex/event/turn_completed` as terminal events.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexNativeSessionController.swift:2438` explicitly ignores `codex/event/task_complete`. The local comment assumes Codex mirrors task completion through `turn/completed`.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:5878` sets visible Codex Agent Mode status to `Thinking...` on `.turnStarted`.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:5896` finalizes only after a correlated `.turnCompleted`. If the controller drops or never emits completion, Agent Mode remains active.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/CodexCLIProvider.swift:70` uses the native Codex app-server path for visible chat, so the same controller/event issue can affect both visible chat and Agent Mode.
- `agent_manage` showed the visible `Scout CE first-install milestone` session still running with only the user prompt in its transcript, confirming RepoPrompt didn't record assistant output or terminal completion for that run.
- A targeted `agent_run` explore launch couldn't start because RepoPrompt rejected the run with a workspace-routing error before provider startup. That's separate from the Codex hang and should be handled as routing/tooling hardening.

## Investigation Log

### Phase 1 - Initial Triage
**Hypothesis:** The hang could be caused by RepoPrompt's UI/orchestration layer, Codex CLI itself, or a local model/configuration mismatch.
**Findings:** RepoPrompt MCP tools responded while visible Codex sessions were stuck. Direct Codex CLI with `gpt-5.5` returned `CODEX_GPT55_SMOKE_OK`.
**Evidence:** `app_settings` returned `models.preferred_compose_model = codex_custom_gpt-5.5-high`; direct `codex exec -m gpt-5.5` returned successfully.
**Conclusion:** Basic Codex CLI access isn't the immediate blocker. The failure is likely in RepoPrompt's Codex provider integration, session orchestration, environment, or how RepoPrompt launches/monitors Codex.

### Phase 2 - RepoPrompt Context Builder
**Hypothesis:** RepoPrompt source would identify the integration path that owns Codex visible chat and Agent Mode.
**Findings:** `context_builder` selected the Codex app-server controller, visible chat provider, Agent Mode coordinator, model registry, and relevant tests. It identified `codex/event/task_complete` handling as a likely lifecycle mismatch.
**Evidence:** The selected code shows visible chat and visible Agent Mode both use `CodexNativeSessionController` for Codex app-server events.
**Conclusion:** The highest-risk code is the app-server lifecycle bridge, not the model catalog alone.

### Phase 3 - Direct Codex App-Server Probe
**Hypothesis:** If Codex app-server itself hangs, this is a Codex issue; if direct app-server completes, RepoPrompt's bridge is the likely failure.
**Findings:** Direct app-server completed a GPT-5.5 turn with the generated `text_elements` input field. The event stream included `turn/started`, assistant deltas, and `turn/completed`.
**Evidence:** Direct probe returned `APP_SERVER_SMOKE_OK` deltas and a final `turn/completed` notification. The same probe using RepoPrompt's camel-case `textElements` shape was rejected.
**Conclusion:** Codex app-server works locally. RepoPrompt must update its request serialization and should harden lifecycle completion handling.

## Root Cause
The observed hang is best classified as a RepoPrompt CE Codex integration bug triggered by Codex app-server protocol drift. Direct Codex CLI and direct Codex app-server both work, but RepoPrompt's app-server bridge still sends stale user-input shape and assumes only canonical `turn/completed` is authoritative. Because `turn/start` intentionally has no timeout, any rejected, mismatched, or dropped terminal lifecycle event leaves visible chat and Agent Mode on `Thinking...`.

## Recommendations
1. Update `CodexNativeSessionController.turnInput` to serialize text spans as `text_elements` while preserving image and local-image fields expected by the generated app-server schema.
2. Add a guarded fallback path that treats `codex/event/task_complete` as terminal only when it strongly correlates with the active thread and active turn. Filter duplicates if a later canonical `turn/completed` arrives.
3. Add regression coverage in `CodexNativeSessionControllerTurnDispatchTests` for the generated `UserInput` wire shape.
4. Add regression coverage in `CodexNativeSessionControllerEventRecoveryTests` for `task_complete`-only completion, duplicate `task_complete` plus `turn/completed`, and stale `task_complete` from another turn.
5. Investigate the separate `agent_run.start` routing error after the Codex lifecycle fix, because it prevents reproducing the hang through a clean MCP-launched explore probe.

## Preventive Measures
- Generate or snapshot Codex app-server protocol types in a test fixture and compare RepoPrompt's hand-built request dictionaries against the current schema.
- Enable usable raw Codex app-server event logging through the documented app setting. `isRawEventFileLoggingEnabled()` currently returns `false`, which makes lifecycle drift harder to diagnose.
- Add a live debug smoke that runs visible Codex chat, visible Codex Agent Mode, and headless `codex exec --json` separately so future failures can be classified by surface.
