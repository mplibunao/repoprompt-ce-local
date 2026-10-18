import Foundation

extension RepoPromptWorkflowPrompts {
	// MARK: - Orchestrate Workflow

	/// The rp-orchestrate command — plans, decomposes, and dispatches work across agents.
	static let rpOrchestrate = rpOrchestrate(variant: .mcp)

	/// Generate rp-orchestrate for a specific variant.
	static func rpOrchestrate(variant: WorkflowPromptVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let suffix: String
		let title: String
		switch variant {
		case .cli: suffix = " (CLI)"; title = "CLI Orchestrator"
		case .agent: suffix = ""; title = "Orchestrator"
		case .mcp: suffix = ""; title = "MCP Orchestrator"
		}
		let toolDesc = variant == .cli ? "rpce-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-orchestrate", description: "Plan, decompose, and delegate complex tasks across multiple agents using \(toolDesc)", variant: variant))

# \(title)\(suffix)

Raw request: $ARGUMENTS

\(variant.preamble)\(rpOrchestrateCore(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance))
"""
	}

	/// Core orchestration workflow content.
	static func rpOrchestrateCore(variant: WorkflowPromptVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let isAgent = variant == .agent
		let cleanupQuickReferenceRow = includeSessionCleanupGuidance
			? "| Dismiss a completed session | `agent_manage op=cleanup_sessions session_ids=[\"...\"]` |\n"
			: ""
		let planRetentionNote = includeSessionCleanupGuidance
			? "Export cleanup never covers the run's plan, even when the plan is an export under `prompt-exports/`.\n\n"
			: ""

		return """
You are an orchestrator: **plan**, **decompose**, **delegate**. Implementation and deep context-gathering happen in sub-agents. Keep your own context lean for coordination.
\(workspaceVerificationBlock(variant: variant, heading: "## Phase 0", beforeAction: "planning", nextStep: "Phase 1"))
## Phase 1: Contextualize the Task

Translate the user's prompt into the codebase's actual nouns — concrete modules, filenames, patterns — so builder can focus immediately instead of disambiguating. 1-2 navigation calls (tree or search) is usually enough.

Example:
- Raw: *"Add retry logic to the API layer"*
- Contextualized: *"Add retry logic to `NetworkService` (HTTP wrapper) — see `APIClient` for the existing auth retry pattern."*

Shortcuts:
- **User named the file/module** → use their reference, skip the scan.
- **User provided a plan file** → read it, skip straight to Phase 2.
- **Still ambiguous after 2 calls** → dispatch a narrow explore agent with one specific question.

Keep this light — builder handles the deep reading.

\(example(variant,
	mcp: """
```json
{"tool":"get_file_tree","args":{"type":"files","mode":"auto"}}
{"tool":"file_search","args":{"pattern":"<key term>","mode":"path"}}
```

Then:
```json
{"tool":"context_builder","args":{
	"instructions":"<contextualized task>",
	"response_type":"plan",
	"export_response":true
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'tree'
rpce-cli -w <window_id> -e 'search "<key term>"'
rpce-cli -w <window_id> -e 'builder "<contextualized task>" --response-type plan --export'
```
"""))

If you can't disambiguate from a quick scan, dispatch a narrow explore agent first:

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Explore: <area>",
	"message":"Check <specific thing> — report back briefly."
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Explore: <area>" message="Check <specific thing>"'
```
"""))

Explore agents are cheap — spawn multiple in parallel for different areas, but keep each prompt narrow. They tend to overthink broad instructions.

---

## Sharing the plan with sub-agents

Once you have a plan — whether generated via builder or provided by the user — you'll want sub-agents to see it. Use `export_response:true` to write any generated plan to a shareable file. This works on:
- **`context_builder`** (with `response_type: "plan"`, `"question"`, or `"review"`) — exports the generated response
- **\(isAgent ? "`ask_oracle`" : "`oracle_send`")** — exports any oracle response, including follow-ups to a context_builder chat

For user-provided plan files, you already have a path — just reference it in dispatch briefs.

The tool returns `oracle_export_path` and `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next `agent_run` `start` call. The `oracle_export_instruction` field is a ready-made sentence ("Read the Oracle export at `<path>` with `read_file` …") you can emit verbatim at the head of that `message`. The child agent opens the file with `read_file`. Do **not** ask child agents to continue your Oracle chat — they are in different tabs.

**The plan stays as approved.** Sub-agents read it as context, and you don't edit it either. Record what happens during the run in the run ledger, so the plan keeps saying what was approved and the ledger says what was done.

\(example(variant,
	mcp: """
```json
// Generate and export the plan in one call
{"tool":"context_builder","args":{
	"instructions":"<task description>",
	"response_type":"plan",
	"export_response":true
}}

// Or export an oracle follow-up
{"tool":"\(isAgent ? "ask_oracle" : "oracle_send")","args":{
	"message":"Plan: <focused planning question>",
	"mode":"plan",
	"export_response":true
}}

// Then reference the export path in the child agent message
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Orchestrate: <goal>",
	"message":"Read the plan at <plan path> with read_file first. Implement <work item>."
}}
```
""",
	cli: """
```bash
# Generate and export the plan, then reference the returned path in agent_run message.
rpce-cli -w <window_id> -e 'builder "<task description>" --response-type plan --export'
rpce-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Orchestrate: <goal>" message="Read the plan at <plan path> with read_file first. Implement <work item>."'
```
"""))

---

## The run ledger

Each run writes one ledger: a short Markdown file that records what the run did, for whoever later needs to know what happened and why. A single-item run still writes one.

**Where it goes.** Write it to `docs/ledgers/<YYYY-MM-DD>-<topic>.md`, dated the day the run starts, or to the repository's own ledger location and naming when its AGENTS.md, or a document it links, gives one. When the run serves an issue or ticket, put its reference after the date, as in `<YYYY-MM-DD>-issue-<number>-<topic>.md`. A run that spans repositories keeps one ledger, in the repository that owns the request. Write it in the checkout where the run's work happens: the run's worktree, if it has one.

**What it holds.** Start from this template:

```markdown
# Run ledger: <topic>

Request: <the issue, ticket, or other request the run serves, or "none"> · Plan: `<plan file name>`

<One or two sentences on what the run set out to do.>

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. <goal> | pending | | |
| 2. <goal> | pending | | |

## 1. <goal>

- Decision: <what was decided, and why>. Source: <"approved plan", "user", a review finding, or "orchestrator judgment">.
- Evidence: <a check and its result, or a link to a pull request comment, CI run, or file in the repository>.
- Deferred: <what remains>.

## Parked decisions

- <Question> Options: <a> or <b>. Recommendation: <a>. Blocks: item <n>. Answer: <added when the user answers>.
```

An outcome is `pending`, `done`, `partial`, `dropped`, or `parked`, and by the end of the run no row is `pending`. List commits by subject line, because rebasing the branch changes their hashes. For a commit in another repository, name that repository and its branch first, and add its pull request once one exists. Leave out any line or section with nothing to record.

**How to write it.**
- You are the ledger's only writer.
- Keep each item's log to a few lines, and leave out narration, transcripts, and tool output.
- Write for a later reader who has only the repository: use repository-relative paths, leave out session, window, or run IDs, link any investigation report or optimization scoreboard the item wrote, and state each decision rather than pointing at the plan or `prompt-exports/`, which may be gone by then.
- Make reversible choices yourself, and record in the item's log the ones a reviewer would want to know, with the reason. Two things wait for the user: an action that a rule, a skill, or their request reserves for their approval, and a choice that can't be undone. When one comes up while the user is away, add it under **Parked decisions** with the question, the options, your recommendation, and what it blocks, then continue with work that doesn't depend on it.
- The ledger never gates a step: a missing or late entry doesn't hold up dispatch, review, or a commit.

**ADRs.** When the repository keeps architecture decision records (its AGENTS.md, or a document it links, says where they live), write each ADR draft the plan contains into that folder during the run. Use the repository's rule for which of the run's own decisions are ADR candidates. If it gives none, a decision is a candidate only when it is hard to reverse, would surprise someone without the background, and involved a real trade-off; every other decision stays in the ledger. The ledger links to the ADR instead of repeating its reasoning.

---

## Phase 2: Decompose into Work Items

Take the plan (from \(builderName) or a user-provided plan file) and break it into **up to 5 discrete work items**.

\(sharedDecompositionGuidance(variant: variant, taskNoun: "item"))

---

## Phase 3: Dispatch

### Default: fresh agent per item

For multi-item work, dispatch a **fresh agent per item**. The plan and the run ledger provide continuity: each agent reads the plan for its item and the ledger for what earlier items did, and reasons with a clean context budget.

The pattern is a **verify-then-dispatch-fresh loop**:

1. **Dispatch** the first work item with a self-contained brief + plan reference.
2. **Wait** for the agent to finish.
3. **Verify** against the plan — did it meet the "done when" criteria from Phase 2? A quick scan of the agent's output and, if needed, a lightweight `file_search` or `read_file` on key deliverables catches drift before it compounds.
4. **Record the item in the run ledger.**
5. **Dispatch the next item fresh**, referencing the plan and the ledger.

Do **not** fire-and-forget the full list. Catching drift early — before the next agent builds on a flawed foundation — is your value as the orchestrator.

**Review per work item, not per branch.** When a run has more than one work item, each dispatched agent requests a `context_builder` review of its own item's diff and applies the verified findings before you dispatch the next item. Independent items dispatched in parallel each run that review on their own diff before you dispatch anything that builds on them. Never defer to a single review of the whole branch: a multi-item diff does not fit a model's context window, and findings caught late compound across items. The small-task skip under *Writing the dispatch brief* is for a run with a single small item.

\(example(variant,
	mcp: """
```json
// 0. Before the first dispatch, create the run ledger with one row per item
{"tool":"file_actions","args":{
	"action":"create",
	"path":"<absolute ledger path>",
	"content":"<the ledger template, filled in>"
}}

// 1. Dispatch item 1 as a fresh agent
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Orchestrate 1/N: <item 1 goal>",
	"message":"Read the plan at <plan path> with read_file first. Your job is item 1: <brief>. Later items are handled separately. Report your decisions and verification results to me. I keep the run ledger."
}}

// 2. Agent completes — verify against the plan.
//    Optionally spot-check a key file:
{"tool":"read_file","args":{"path":"<key file from item 1>"}}

// 3. Record the item in the run ledger:
{"tool":"apply_edits","args":{
	"path":"<ledger path>",
	"search":"| 1. <item 1 goal> | pending | | |",
	"replace":"| 1. <item 1 goal> | done | pair · Orchestrate 1/N: <item 1 goal> | `<commit subject>` |"
}}

// 4. Dispatch item 2 as a new fresh agent:
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"pair",
	"session_name":"Orchestrate 2/N: <item 2 goal>",
	"message":"Read the plan at <plan path> and the run ledger at <ledger path> with read_file first. Item 1 is complete. Your job is item 2: <brief>. Report your decisions and verification results to me. I keep the run ledger."
}}
```
""",
	cli: """
```bash
# 0. Before the first dispatch, create the run ledger with one row per item
rpce-cli -w <window_id> -e 'call file_actions {"action":"create","path":"<absolute ledger path>","content":"<the ledger template, filled in>"}'

# 1. Dispatch item 1 as a fresh agent
rpce-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Orchestrate 1/N: <goal>" message="Read the plan at <plan path> with read_file first. Your job is item 1: <brief>. Report your decisions and verification results to me. I keep the run ledger."'

# 2. Verify output, spot-check key files
rpce-cli -w <window_id> -e 'read "<key file from item 1>"'

# 3. Record the item in the run ledger
rpce-cli -w <window_id> -e 'call apply_edits {"path":"<ledger path>","search":"| 1. <goal> | pending | | |","replace":"| 1. <goal> | done | pair · Orchestrate 1/N: <goal> | <commit subject> |"}'

# 4. Dispatch item 2 as a new fresh agent
rpce-cli -w <window_id> -e 'agent_run op=start model_id=pair session_name="Orchestrate 2/N: <goal>" message="Read the plan at <plan path> and the run ledger at <ledger path> with read_file first. Item 1 is complete. Your job is item 2: <brief>. Report your decisions and verification results to me. I keep the run ledger."'
```
"""))

### When steering one agent through multiple items works better

Sometimes it's better to keep a single agent alive and steer it through work. Consider steering when:

- **Tightly coupled items** — item 2 builds directly on a decision the agent made in item 1's working memory.
- **Codex-family sub-agents** — Codex sessions compact reliably, making extended steering a natural fit.
- **Many tiny items** — spawn overhead outweighs context cost.

\(sharedRolesOnlyCheck(variant: variant))

When steering, the loop is the same but step 5 becomes `agent_run op=steer` on the existing `session_id` instead of a fresh dispatch:

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"steer",
	"session_id":"<session_id>",
	"message":"Item 1 looks good. Moving on to item 2: <brief>. Refer back to the plan at <plan path> if needed.",
	"wait":true
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_run op=steer session_id="<session_id>" message="Item 1 looks good. Moving on to item 2: <brief>" wait=true'
```
"""))

### Choosing the right agent role

- **`pair`** — The default for complex work. Architectural decisions, multi-file changes, deep reasoning.
- **`engineer`** — Well-scoped items where the goal and approach are already clear from the plan.
- **`design`** — UI, layout, visual polish, copy/text editing, anything user-facing.
- **`explore`** — Short reconnaissance only (already used in Phase 1 escalation path).

Stick to these role labels. The specific model behind a role isn't your concern unless the user names one.

When in doubt, use `pair`. The tasks reaching this workflow are complex by nature. Use `engineer` when the plan already makes the path obvious and the item just needs execution.

When questions arise during coordination, reason through them yourself. If you're uncertain, negotiate with the agent already working on the relevant task — it has the deepest context. Steer it with your thinking and work toward consensus rather than dictating a direction.

### Writing the dispatch brief

\(sharedDispatchBriefGuidance(variant: variant))

### Parallel dispatch

\(sharedParallelDispatchBlock(variant: variant, defaultRole: "pair"))

\(sharedSessionCleanupSection(variant: variant, heading: "### Housekeeping", includeSessionCleanupGuidance: includeSessionCleanupGuidance, includeStrayPlanExportCleanup: true))
\(planRetentionNote)---

## Phase 4: Monitor and Verify

\(sharedMonitorAndVerifyBlock(variant: variant, recordStep: "Record the item's outcome, or the gaps you found, in the run ledger."))

\(sharedFinalRollupBlock(variant: variant, taskNoun: "item"))

The final rollup also gives:
- The run ledger's path.
- ADR candidates, when the repository keeps ADRs: decisions made during the run that meet the ADR rule given under **ADRs**. Write the ones the user approves into the repository's ADR folder.
- One line about the plan. For an untracked plan: "I'll delete `<plan path>` when you tell me the work is done." For a plan git tracks: "`<plan path>` is tracked, so it stays and follows the repository's own plan lifecycle."

### Quick reference: orchestrator operations

| Operation | Tool call |
|-----------|-----------|
| Start a fresh agent | `agent_run op=start model_id=<role> session_name="..." message="..." detach=true/false` |
| Steer an existing agent | `agent_run op=steer session_id="..." message="..." wait=true` |
| Wait for an agent | `agent_run op=wait session_id="..."` |
| Wait for first of multiple agents | `agent_run op=wait session_ids=["...", "..."] timeout=60` |
| Poll without blocking | `agent_run op=poll session_id="..."` |
| Poll multiple agents | `agent_run op=poll session_ids=["...", "..."]` |
\(cleanupQuickReferenceRow)| Read plan/context | `read_file`, `get_file_tree`, `file_search` |
| Create or update the run ledger | `file_actions` (`action:"create"`), then `apply_edits` |
| Reason with oracle | `\(isAgent ? "ask_oracle" : "oracle_send")` — requires file selection from \(builderName) |

---

## Phase 5: Close Out

The plan the run worked from, whether a `docs/plans/` file or a `prompt-exports/` export, stays until the user says the work is done. Finishing the items, passing CI, or a merge doesn't count, because review and feedback usually follow.

Bring up deleting it at two moments only:
1. In the final rollup, with the one line about the plan.
2. When the user approves the finished work, for example "looks good" or "merge it", ask once: "Is the work done, so I can delete `<plan path>`?" Approving the plan, or a single item, doesn't count.

When the user says the work is done:
1. Check that git doesn't track the plan: in your shell, `git ls-files -- <plan path>` prints nothing. If git tracks it, leave it in place and stop here, because that repository keeps its plans under its own lifecycle.
2. Check that each decision in the plan is in the run ledger or an ADR, and that each deferral is in the run ledger. Tell the user what is missing, and record it before you delete anything.
3. Delete the plan by its absolute path with `file_actions`, which moves it to the Trash.

---

## Key Principles

- **You are the coordinator, not the implementer.** Read to verify sub-agent work, not to build your own mental model. Keep your context focused on coordination.
- **Trust the agents.** They're smart, they have tools, they read project instructions. Give them goals and reference points, not turn-by-turn directions.
- **Be strategic about parallelism.** Independent items can run concurrently, but always warn agents about siblings working in adjacent areas.
- **Graceful scaling.** 1 item = just dispatch it. 2-3 items = straightforward. 4-5 items = be deliberate about dependencies and parallelism.
- **Escalation point.** You're the one with the full picture. Sub-agents should surface coordination problems to you rather than solving them unilaterally.

## Anti-patterns

- 🚫 Implementing code yourself — you're the orchestrator, dispatch an agent\(isAgent ? "" : "\n- 🚫 Skipping Phase 0 (Workspace Verification) — you must confirm the target codebase is loaded first")
- 🚫 Extended code reading before delegating — a quick skim is fine; deep reads belong in builder or explore agents
- 🚫 Writing detailed step-by-step instructions for dispatched agents — they can reason for themselves
- 🚫 Dispatching parallel agents to overlapping files without warning them about each other
- 🚫 Waiting idle for an agent when you could be dispatching the next independent item or preparing the next brief
- 🚫 Forgetting to check on dispatched agents — they may block on permission approvals; poll periodically to keep them unblocked
- 🚫 Creating 5 work items when the task is naturally 2 — decompose to the right granularity, not a target number
- 🚫 Repeating project conventions from CLAUDE.md in dispatch briefs — the agents will read those themselves
- 🚫 Forwarding user-to-orchestrator commentary (preferences, criticisms, meta-instructions about how you should operate) into a peer-agent brief — translate the actionable parts into the technical task and keep the rest between you and the user
"""
	}

}
