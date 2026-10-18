# Spike findings: codex 0.145.0 hook trust lifecycle (upstream issue 665)

> Investigation report, observed 2026-07-28 on the bundled `codex-cli 0.145.0`. It records what was true then. Where it disagrees with a current document, the current document is right.
> Current guidance: [docs/architecture/codex-app-server-schema-gate.md](../architecture/codex-app-server-schema-gate.md), Bounded contract.

Runtime: bundled codex `codex-cli 0.145.0` from `/Applications/RepoPrompt CE.app/.../BundledRuntimes/Codex/aarch64-apple-darwin/bin/codex`, driven over stdio JSON-RPC (v1 `initialize` + `initialized`, then `thread/start`/`turn/start`/`hooks/list`/`config/batchWrite`). Scratch repo with a nested-schema PreToolUse hook; scratch CODEX_HOME with project trust only (no hooks.state). Driver + raw transcripts lived in `/tmp/hook-spike-665` (deleted after this report; key shapes preserved verbatim below).

## Verdicts

**A. Live-thread reload: YES — no rebinding needed.** Sequence on one thread: turn 1 with untrusted hook → hook silently skipped, command executed. `config/batchWrite` upsert of `hooks.state` with `reloadUserConfig: true` → `hooks/list` reports `trusted` → turn 2 **on the same thread** → `hook/started` fired. The rebind-after-write design branch is dead; the plan's primary lifecycle stands as designed.

**B. CE-style thread config overrides: no interference.** Same sequence with a `config` bag on `thread/start` (tool_output_token_limit, features.* toggles, memories.*, model_reasoning_summary): identical results.

**C. Concurrent cross-process writes: UNSAFE — last-writer-wins.** Two app-server processes sharing one CODEX_HOME, simultaneously upserting different hooks.state keys: both responses report `status: "ok"` (with different resulting `version` hashes), but the final config contains only one key — 5/5 rounds. `config/batchWrite` is read-modify-write from a per-process snapshot with no cross-process merge or locking. **CE must serialize trust writes across its controllers (app-global mutex).** External writers (terminal TUI) remain the accepted TOCTOU class.

**D. Blocking semantics: the hook must write the denial reason to stderr.** A hook exiting 2 with stdout-only output produces `hook/completed status: "failed"` with entry `"PreToolUse hook exited with code 2 but did not write a blocking reason to stderr"` — and **the command executes anyway** (fail-open on malformed hook error). With the reason on stderr: `status: "blocked"`, feedback entry carries the text, command never runs. E2E canaries must use stderr-writing hooks. (The work repository's guardrails write to stderr, so their chain is well-formed.)

## Additional discoveries

- **Hook declaration schema is strict and silently enforced**: a flat `command` key on the `[[hooks.PreToolUse]]` matcher table is ignored — zero hooks AND zero `errors`/`warnings` in `hooks/list`. Only the nested form is discovered:
  ```toml
  [[hooks.PreToolUse]]
  matcher = "^Bash$"

  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = '"$(git rev-parse --show-toplevel)/.codex/hooks/deny.sh"'
  timeout = 30
  ```
  Consequence: schema-invalid hook configs are protocol-indistinguishable from hook-less repos; the plan's `errors`-array fail-closed rule cannot catch this class. Candidate codex upstream report.
- **Project trust gates discovery**: without a `[projects."<path>"] trust_level = "trusted"` entry in the effective home, `hooks/list` returns zero hooks for the repo (no "untrusted" listing, no errors). Confirmed by config bisection against a private work repository: the trust section alone flips listing from 0 to 2 hooks. Implication for CE: repos not yet trusted in the private home won't even *list* their hooks — the hook gate composes with CE's existing project-trust handling; a repo with no trust shows no hooks and the gate stays silent (consistent with codex's own model: trust the project first).
- **Near-simultaneous app-server spawns on one CODEX_HOME race at startup** — one process can die immediately (broken pipe on first write). A ~1s stagger avoids it. Relevant to CE only insofar as multiple controllers share the private home; CE staggers naturally.
- `hooks/list` `key` is byte-identical to the `[hooks.state]` table key, and `currentHash` is the exact `trusted_hash` value to write — confirmed live (write built purely from list output produced `trusted`).

## Verbatim protocol shapes (for the contract fixture)

hooks/list request/response (fields observed on 0.145.0):
```json
{"method": "hooks/list", "params": {"cwds": ["/abs/repo"]}}
```
Response `result.data[]` (per-cwd `HooksListEntry`): `cwd`, `hooks[]`, `errors[]`, `warnings[]`.
`hooks[]` (`HookMetadata`): `key`, `eventName`, `handlerType`, `matcher`, `command`, `timeoutSec`, `statusMessage`, `additionalContextLimit`, `sourcePath`, `source`, `pluginId`, `displayOrder`, `enabled`, `isManaged`, `currentHash`, `trustStatus`. Sample:
```json
{"key": "/abs/repo/.codex/config.toml:pre_tool_use:0:0", "eventName": "preToolUse", "handlerType": "command", "matcher": "^Bash$", "command": "\"$(git rev-parse --show-toplevel)/.codex/hooks/deny.sh\"", "timeoutSec": 30, "statusMessage": null, "additionalContextLimit": null, "sourcePath": "/abs/repo/.codex/config.toml", "source": "project", "pluginId": null, "displayOrder": 0, "enabled": true, "isManaged": false, "currentHash": "sha256:e6a5...", "trustStatus": "untrusted"}
```

config/batchWrite request/response:
```json
{"method": "config/batchWrite", "params": {"edits": [{"keyPath": "hooks.state", "value": {"<key>": {"trusted_hash": "sha256:..."}}, "mergeStrategy": "upsert"}], "reloadUserConfig": true}}
```
```json
{"result": {"status": "ok", "version": "sha256:<config-file-hash>", "filePath": "<home>/config.toml", "overriddenMetadata": null}}
```

hook/started + hook/completed notification `params.run` fields: `id`, `eventName`, `handlerType`, `executionMode`, `scope`, `sourcePath`, `source`, `displayOrder`, `status` (`running`/`completed`/`failed`/`blocked`), `statusMessage`, `startedAt`, `completedAt`, `durationMs`, `entries[]` (`kind`: `feedback`/`error`/..., `text`).

## Plan impact
- Reload risk resolved favorably (primary design stands; rebind branch removed).
- CE-side app-global trust-write mutex is REQUIRED (was conditional).
- E2E canary must use a stderr-writing deny hook.
- `errors`-array protection has a documented boundary (schema-invalid configs invisible).
- The gate composes with project trust: untrusted repos list no hooks; the hook gate does not subsume or replace trust handling.
