# Run ledger: Terraform codemaps

Request: none · Plan: `terraform-codemaps-2026-10-28.md`

Add Terraform (`.tf`) outlines to CodeMap, plus graph links that follow Terraform's folder-scoped modules: a module call to the child module's folder, each call argument to the child's `variable`, and `module.<call>.<output>` to the child's `output`. Four stacked pull requests deliver it, each implemented by its own thread, which adds its own rows and sections here. They're based on PR 0, the edge-ambiguity fix in #309, which has its own ledger: `docs/ledgers/2026-10-28-issue-302-codemap-edge-ambiguity.md`.

| Item | Outcome | Agent session | Commits |
|------|---------|---------------|---------|
| 1. Baseline and architecture approval | done | | |
| 2. Grammar integration (PR 1) | done | engineer · TF codemaps PR 1: pin TreeSitterHCL and prove linkage | `build(codemap): pin the tree-sitter HCL grammar` |
| 10. Contribution gates (PR 1) | done | engineer · TF codemaps PR 1: independent review; pair · TF codemaps PR 1: cleanup pass | `docs(ledgers): add the run ledger for the Terraform codemaps stack` |

## 1. Baseline and architecture approval

- Decision: the plan was approved on 2026-10-28, which approves its ADR draft for the two persisted formats, the Terraform artifact payload with its global schema bump and the `tf1` contribution tuples, which PR 2 commits under `docs/adr/`. Source: user.
- Decision: the stack is PR 1, grammar integration; PR 2, the artifact contract and extraction, with the ADR; PR 3, contributions and the qualified graph; PR 4, enabling `.tf` and its consumers, followed by the live checks and the agent-task comparison in the debug app. PR 1 is based on PR 0's branch, and each later pull request on the one before it. PRs 2, 3, and 4 land in one release candidate, so the schema and contribution-policy bumps rebuild saved codemaps once. Source: user.
- Decision: an edge is ambiguous only when every matched name has more than one definer, and its candidate count is the smallest among its matched names. PR 0 implements it. Source: user.
- Decision: the scope is RepoPrompt CE codemaps only. Outlines may leave out descriptions and validations. A `.tf` file with a syntax error doesn't show an outline or links until it parses again. Every language's saved codemaps rebuild once after the upgrade. Source: user.
- Decision: fixtures and examples are synthetic. The private Terraform repository is a read-only validation corpus for PR 4's live checks only, and nothing from it enters commits, tests, pull requests, or issues. Source: user.
- Deferred: registry and Git module sources (#300), `.tfvars` links (#303), `terraform_remote_state` links (#304), `.tf.json` files (#305), module sources built from `const` variables (#306), and override files (#307).

## PR 1: grammar integration

Branch `chore/tf-codemaps-1-grammar`. Base: PR 0's branch `bugfix/302-codemap-edge-ambiguity` at `4a7f4aafd`, which branches from `main` at `2f012210b`.

### 2. Grammar integration

- Decision: pin `tree-sitter-grammars/tree-sitter-hcl` at exact version `1.2.0`, which resolves to `fad991865fee927dd1de5e172fb3f08ac674d914`, the commit its `v1.2.0` tag points at, and link its `TreeSitterHCL` product into `RepoPromptCodeMapCore` only. The same revision is in `Package.resolved`, the guardrails, and the tree-sitter attribution README. PR 2's grammar recipe must use it as Terraform's grammar revision, and nothing automated compares the two. Source: approved plan for the pin, and the independent review for the note about the revision.
- Decision: the only source change is `import TreeSitterHCL` in `CodeMapSyntaxEngine.swift`, which the guardrails' required-imports check now names. No language, extension, grammar recipe, or query is registered, so `.tf` files still don't get a codemap. Source: approved plan.
- Decision: no committed test. The pin does nothing on its own until PR 2 registers the grammar, and PR 2's golden tests parse `.tf` fixtures through it. A throwaway probe showed the linkage instead. Source: orchestrator judgment, following `rpce-test-quality`.
- Evidence: `make guardrails`, `Scripts/swiftpm_notice_guardrails.sh`, `make dev-swift-build PRODUCT=all`, and `make xcode-validate` passed. The build compiled `TreeSitterHCL` with no warnings from the package and linked `RepoPrompt` and `repoprompt-mcp`. `make dev-format` changed 0 files, and `make dev-lint` passed.
- Evidence: the throwaway probe, a test in `RepoPromptCodeMapCoreTests` that was deleted before the commit, set a parser to `tree_sitter_hcl()`. The pinned runtime accepts ABI versions 13 to 15, and the grammar is ABI 15. It parsed synthetic HCL containing a heredoc and a `${}` interpolation into a tree with `heredoc_template` and `template_interpolation` nodes and no errors, so the external scanner ran. An unterminated block in the same test reported an error.
- Evidence: the package lists `src/parser.c` and `src/scanner.c` unconditionally, so it links without a `TreeSitterScannerSupport` copy, unlike JavaScript and Python. Its manifest declares `tree-sitter/swift-tree-sitter` for its test target only, which has the same SwiftPM identity as the `repoprompt/swift-tree-sitter` fork; the fork's pin didn't change, and the C, Go, JavaScript, Python, and PHP grammars already declare the same dependency.
- Evidence: `LICENSE-tree-sitter-hcl.txt` is byte-identical to the `LICENSE` at the pinned commit, both in the resolved checkout and on GitHub. The package is Apache-2.0 and doesn't include a NOTICE file.
- Evidence: the debug-app run went from 11:39 to 11:50 (+0800) on 2026-10-28. `make dev-smoke-launch` built this branch at `d4ed7515c` (not dirty) and launched the debug app. Its smoke then failed at `workspace switch` while window 1 restored its saved workspace, and a rerun of `make dev-smoke` against the same app passed. In a disposable synthetic Git repository opened as its own workspace, `get_code_structure` returned the outline of a Swift struct, and for a `main.tf` holding a `variable`, a `module` call with a local source, and an `output` it returned `unavailable` with `seed_not_indexed`, while the root's index was complete. Cleanup deleted the workspace and the fixture, and the debug app was stopped at 11:59. Production RepoPrompt CE kept the same process ID and start time throughout and was never driven.

### 10. Contribution gates (PR 1)

- Decision: the grammar change was committed before the debug-app run and the review, in the order `CONTRIBUTING.md` step 4 gives, and the review quoted a pull request draft that included that run. The review and the cleanup pass ran as fresh Agent sessions bound to this worktree, from the prompts in `.agents/skills/rpce-merge-pr-batch/references/review-prompts.md`, in place of Context Builder, because the orchestrator's compose tab reads the main checkout, which doesn't contain this branch. Source: orchestrator judgment.
- Evidence: the independent review found nothing. It checked that the URL, version, revision, and product agree in all five places and that the revision is the tag's commit; that the grammar's test-only `swift-tree-sitter` dependency can't displace the fork; that no CodeMap cache key or pipeline identity is derived from the package graph, `Package.resolved`, or the imported modules, so the pin alone doesn't invalidate saved codemaps; that the attribution bundle and its checksums are complete; and that no tooling, CI workflow, or guardrail fixture hard-codes the grammar set.
- Evidence: the cleanup pass didn't change anything. Each new line sits where its file's ordering puts it.
