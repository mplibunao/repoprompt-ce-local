# Project the global Codex `hooks.json` into RepoPrompt's isolated Codex home and approve user hooks in Agent Mode

Status: accepted, 2026-11-18
Sources: `docs/ledgers/2026-11-18-codex-global-hooks.md`

## Context

RepoPrompt runs every Codex process with its own `CODEX_HOME`, the directory where Codex keeps its configuration, hook trust, and sessions. This private Codex home keeps Agent Mode from depending on, or changing, an ordinary Codex install in `~/.codex`. The only Codex state copied from `~/.codex` is `AGENTS.override.md` and `AGENTS.md`. A projection copies them into the private Codex home on each launch. It records each copy's hash in a manifest, `.repoprompt-agents-projection.json`, and refuses to overwrite a file it doesn't own or one that was edited.

A Codex hook is a shell command that Codex runs at an event such as `PreToolUse`. Codex runs a hook only after its exact definition is trusted. It stores that trust as a hash in the `[hooks.state]` table of the `config.toml` in the effective `CODEX_HOME`, keyed by the absolute path of the file that defines the hook. Codex reports a hook from `$CODEX_HOME/hooks.json` with source `user` and a hook from a repository's own Codex configuration with source `project`. Agent Mode's first-turn approval gate, which pauses a session's first turn until its hooks are reviewed, reviewed only `project` hooks.

Upstream (`repoprompt/repoprompt-ce`) excluded global hooks by design: isolation makes them invisible rather than untrusted (upstream issue 665), and upstream PR 837 states "No global hook bridge." `docs/investigations/codex-bundled-vs-local-appserver-2026-09-05.md` records the exclusion. Global hooks don't run in Agent Mode. A global `PreToolUse` hook from the rtk command-line tool never fires, although it would rewrite `git status` to `rtk git status`. Bundled Codex 0.159.0 loads a `hooks.json` in the private Codex home as a `user` hook, but trust given in `~/.codex` doesn't apply there, because the trust key contains the file's path.

## Decision

- Copy `~/.codex/hooks.json` byte for byte into the private Codex home whenever RepoPrompt prepares Codex state, which every Codex launch path does. `hooks.json` has the same ownership rules as the instruction files, under a manifest of its own, `.repoprompt-hooks-projection.json`. `.repoprompt-agents-projection.json` is unchanged and lists `AGENTS.override.md` and `AGENTS.md` only.
- Keep the two manifests apart because a build rejects a manifest that lists a file it doesn't know, and then fails every Codex launch. Only a manifest that older builds never read can name `hooks.json`. The instruction files reconcile first, so a conflict on `hooks.json` neither blocks nor undoes that reconcile, though the launch still reports the conflict.
- Treat hooks with source `user` like hooks with source `project` in the first-turn approval gate: reviewable, trusted through the Codex app-server's `config/batchWrite`, and verified by a fresh `hooks/list`. Other sources are never offered. The approval card and the MCP interaction show each hook's source, source path, matcher, and full command.
- Hook trust stays in the private Codex home's `[hooks.state]`. Each hook is approved there, and trust in `~/.codex/config.toml` doesn't carry over.
- No other `~/.codex` state crosses over. Inline `[hooks]` in `~/.codex/config.toml` isn't projected.
- Hook discovery warnings never block the first turn. When the gate's first discovery finds warnings and nothing to review, it appends one transcript notice.

## Alternatives considered

- Keep the isolation boundary: global hooks silently don't run in Agent Mode.
- Replace the manifest with a new receipt, as upstream PR 837 does: existing instruction copies become unowned files, and an unowned file fails every Codex launch until someone moves or removes it.
- One manifest for all three files: every branch's debug build on a machine shares one debug profile. A build that projects `hooks.json` would list it in the shared instructions manifest, and every other branch's debug build would then fail every Codex launch until it rebased.
- Import trust from `~/.codex/config.toml`: the keys contain the file's path and don't match, and silently inheriting trust in executable code weakens consent.
- Point `CODEX_HOME` at `~/.codex`: it abandons isolation entirely.
- Block the first turn on any hook discovery warning: Codex 0.159.0 also warns about hooks that still load, and the trust write and its post-write verification decode the same `hooks/list` response as the gate, so a blocking warning would stop approval of every hook while it persists.

## Consequences

- An approved global hook runs in Agent Mode without per-session setup. RepoPrompt keeps the approval for that build profile until the hook's definition changes.
- An approved global hook runs in every Codex process of that build profile, because they all share the private Codex home's `config.toml`. A `PreToolUse` hook on the shell tool matters only in Agent Mode, since Chat and Context Builder turn the shell tool off. A trusted hook on another event, such as session start, can also run in Chat and Context Builder.
- An MCP caller can approve global hooks, as it can approve project hooks. Codex hook approval strict mode, the setting that makes Continue Without Hooks unavailable, restricts only skipping them.
- An edit to `~/.codex/hooks.json` reaches the private Codex home the next time RepoPrompt prepares Codex state, which every launch of a Codex process does. A running Codex controller then reports the changed hook as `modified` and stops running it without a prompt, and the next controller Agent Mode starts for a session reviews it again.
- Removing `hooks.json` from `~/.codex` removes the copy on the next launch but keeps the trust records.
- Agent Mode sessions that start in parallel and find the hook unresolved each pause on their own review.
- A global hook can fail when something it depends on isn't in the private Codex home, and editing the managed copy there can block Codex launches. [`docs/releasing.md`](../releasing.md#bundled-codex-artifact) has the operating rules.
- A build that doesn't project `hooks.json` ignores the hooks manifest and the copy, and its own projection and manifest work as before. Its Codex still loads `$CODEX_HOME/hooks.json` as a `user` hook, but its approval gate offers only `project` hooks. Codex skips an untrusted hook but still runs one whose exact definition is already trusted in that home, as when a build that projects `hooks.json` approved it.
- A production rollback restores both manifests, the `hooks.json` copy, and its trust in `config.toml` together, because the [rollback unit](../releasing.md#rollback-unit) archives `Codex/` along with every other top-level Application Support entry except developer infrastructure.
- `docs/architecture/codex-app-server-schema-gate.md` records that the schema gate can't pin the `user` source value.
- Revisit if upstream adds a supported global-hook bridge, or if Codex changes hook keying or `source` values.
