# Worktree startup benchmark campaigns, June 2026

`Scripts/worktree_startup_live_benchmark.py` drives the large-root and
linked-worktree startup benchmarks. This report records the two campaigns run
with it in June 2026, worktree interactive readiness and content-addressed
codemaps, together with the detailed checks its lanes apply. The commands for
running the lanes today are in [Live large-workspace worktree-startup
diagnostic](../testing.md#live-large-workspace-worktree-startup-diagnostic).
Where this record and the script disagree, the script is current. Paths to the
original operator's checkout are shown as placeholders.

## Interactive-readiness iteration 0 campaign

The worktree interactive-readiness campaign uses additive DEBUG diagnostic
schema 5. Production route behavior is unchanged. Its authoritative iteration-0
root is the real RepoPrompt CE main checkout in the dedicated
`RPCE Search Bench Main 20260618` workspace (or a clearly owned equivalent real
clone), never the active development tab/workspace. Synthetic repositories are
allowed only by `self-test` and are labeled non-authoritative.

Each route/width/process series is predeclared as exactly one excluded warmup
plus five retained samples. Keep every valid slow sample and never replace an
ordinal. The primary value is the app-monotonic interval from
`bindingTransitionStarted` to the later successful direct `file_search` or
`read_file` completion. Search/read start concurrently. Report the five raw
values, p50, nearest-rank p95, and sample CV. CV above 50% requires a distinct
predeclared confirmation plan with another one-plus-five series; do not pool the
series, and accept a direction only when both agree.

Primary performance validity is intentionally separate from follow-on
acceptance. Immediately after concurrent direct search/read, the harness takes
a correlation-bound diagnostic checkpoint. `primary_performance` requires the
exact correlation/session/context/invocation/ordinal/build identity, ordered
root/search/read boundaries, both the recorded concurrent outcome with empty
mark failures and strict cross-operation interval overlap, successful structured direct probes with logical
canonical display plus exact physical `worktree_scope`, the frozen committed
path/blob markers, exactly one unambiguous correlation-bound receipt decision
at the consumption terminal stage with route-specific creation/coordinator/
projection/consumption semantics, the exact actual route, no
fallbacks, and final resource/cleanup proof. Codemap, passive tree, and
selection are stored under `follow_on_acceptance`. A follow-on failure remains
campaign-blocking and visible but does not discard a valid primary value.
Follow-on collection is total: timeout/malformed results are typed, every
configured operation records exact start/completion mark outcomes, a failed
start mark cannot be replaced by validator success, selection completes only
after its selection-get result is recorded, later follow-ons still run, and the
final diagnostic export is attempted once without retry or ordinal replacement.
Acceptance validates the exact typed operation and failure inventory plus the
collection-completed mark. `get_code_structure` keeps its internal 10-second
deadline; the harness supplies no model-controlled wait field.

Plan and preflight the real root with explicit ownership and dedicated-workspace
confirmation:

```bash
OWNER_TOKEN="$(uuidgen)"
python3 Scripts/worktree_startup_live_benchmark.py create-marker \
  --root-path /absolute/path/to/repoprompt-ce-checkout \
  --workspace-id '<workspace-uuid>' --root-id '<root-uuid>' \
  --owner-token "$OWNER_TOKEN" \
  --confirm-real-repository-benchmark --confirm-dedicated-workspace

python3 Scripts/worktree_startup_live_benchmark.py plan \
  --workspace-name 'RPCE Search Bench Main 20260618' \
  --window-id '<window-id>' --workspace-id '<workspace-uuid>' \
  --context-id '<context-uuid>' --root-id '<root-uuid>' \
  --root-path /absolute/path/to/repoprompt-ce-checkout \
  --owner-token "$OWNER_TOKEN" --dataset-label rpce-real-readiness-iteration-0 \
  --asserted-file-count '<exact-git-ls-files-count>' --base-ref HEAD \
  --search-marker WorkspaceRootSeedPlanner \
  --read-path Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceRootSeedPlanner.swift \
  --read-marker 'import CryptoKit' --invocations-per-series 1 \
  --confirm-real-repository-benchmark --confirm-dedicated-workspace \
  --output /tmp/rpce-real-readiness-iteration-0.json

python3 Scripts/worktree_startup_live_benchmark.py preflight \
  --plan /tmp/rpce-real-readiness-iteration-0.json \
  --confirm-live-debug-app --confirm-dedicated-workspace
```

For an offline revalidation of an immutable forced-full one-plus-five artifact,
persist the exact artifact-file hashes, per-sample checkpoint and source-record
hashes, harness/validator source hash and version, exact command, sample
identities, and unchanged warmup/retained raw values:

```bash
python3 Scripts/worktree_startup_live_benchmark.py revalidate-primary \
  --plan '<frozen-primary-plan.json>' \
  --artifact '<forced-full-artifact-directory>' \
  --output '<primary-revalidation-provenance.json>'
```

This command is offline and accepts only an exact width-1 forced-full artifact
with one warmup and five retained ordinals. It fails closed on mixed identities,
changed raw values, missing hashes, invalid primary checkpoints, resource
failure, or incomplete cleanup; it does not rewrite the source artifact.

Run width 1 forced-full, then projected. Do not run widths 4/8 or aged until
width-1 projected has exactly `{"diffSeedServing":1}` and an empty fallback map:

```bash
for ROUTE in forced-full projected; do
  python3 Scripts/worktree_startup_live_benchmark.py run \
    --plan /tmp/rpce-real-readiness-iteration-0.json \
    --route "$ROUTE" --process-state warm --checkout-kind linked-worktree \
    --width 1 --invocation 1 --warmups 1 --samples 5 \
    --confirm-live-debug-app --confirm-process-state \
    --confirm-dedicated-workspace
done
```

Timing evidence comes from the correlation-bound primary checkpoint and direct
structured tool results, not inference wall time or assistant prose. Session-bound tools
must keep CE's logical canonical root display while `worktree_scope` proves the
exact physical binding by worktree ID; never require the displayed root path to
equal the app-managed worktree path. Schema-v5 samples require every readiness
boundary, monotonic phase order, duration consistency, attributed passive-tree
work, and configured marker-publication evidence. The small inference gate
separately checks exact raw tool-call/result order and forbidden-tool absence.
Retain root/search/read in `primary_performance`; retain first and warm codemap,
passive tree, selection, Git/filesystem/planner/lock, and marker evidence in
`follow_on_acceptance`; retain CPU/RSS/physical-footprint, cleanup, and
actual-route evidence for both validity decisions. Append iteration results to
`docs/investigations/optimize-worktree-interactive-readiness-runs.md`.

## Iteration 1 measurement-integrity remediation

Resource receipts publish absolute resident/physical-footprint values and their
deltas independently on a 0.1 MiB grid. Validation therefore accepts a displayed
arithmetic discrepancy of exactly 0.1 MiB and rejects 0.2 MiB; all fields must
remain finite and on that published grid. This tolerance does not weaken CPU,
availability, sample-count, peak-ordering, or other resource gates.

Every armed start is written to `state.json` before `agent_run.start`. Normal and
resumed cleanup use the same bounded state machine: status-free
`manage_worktree list`; exact correlation/control recovery and cooperative abort;
cancel or terminalize; unbind/release logical ownership; one session-specific
store-drain proof; physical cleanup; then a second status-free inventory and
final drain proof. Recovery never requests `include_status`. Missing, expired,
timed-out, nonzero, or ambiguous evidence sets `manual_cleanup` and preserves the
physical resource. The DEBUG recovery registry and drain snapshot are bounded
diagnostic records, not enterprise file-count limits; they return IDs, counts,
digests, phases, and actor-entry delay, never raw enterprise paths.

After a same-build projected one-plus-five artifact is valid, run one
non-aggregatable real Agent Mode gate:

```bash
python3 Scripts/worktree_startup_live_benchmark.py live-inference-gate \
  --plan /tmp/rpce-real-readiness-iteration-0.json \
  --projected-artifact '<valid-projected-artifact-directory>' \
  --confirm-live-debug-app --confirm-owned-resources
```

The gate fails unless the raw transcript contains exactly one ordered
`file_search` call/result pair followed by one `read_file` call/result pair, no
other tool, terminal `completed`, and the fixed sentinel. Spartan transcript
events prove invocation/order only. Exact same-context direct structured probes
must independently prove logical root, physical `worktree_scope`, worktree ID,
path, and content, with exact correlation/session/invocation/ordinal,
`{"diffSeedServing":1}`, and empty fallbacks. Assistant prose and inference wall
time are never evidence.

## Interactive-readiness plan

The current interactive-readiness plan freezes
baseline, forced-full, and projected routes; warm and aged linked-worktree
process states; widths 1/4/8; a 30% primary improvement gate; and a 10%
secondary-regression gate. Cold/main-root evidence is recorded separately as
external provenance. Do not add implicit cold, width-2, 40%, or 5% requirements
in the runner or aggregate. Correctness scenarios still cover nested inherited
Agent Mode, selection and `get_code_structure`, exact-root/cross-root negatives,
non-Git behavior, watcher changes, and ordinary/worktree root churn.

## Route accounting

Repeat for `baseline`, `forced-full`, and `projected`; process states `cold`,
`warm`, and `aged`; and widths 1/2/4/8. Automated route samples are always
app-created `linked-worktree` starts. `baseline` is the ordinary automatic
full-crawl control.
`forced-full` forces that safe route. `projected` is valid only when the export
contains exactly one `diffSeedServing` publication, no `fullCrawl`, and no
fallback. Observation/full-crawl data is work-attribution evidence, not a
projected-serving latency sample.

Actual-route accounting is exact: baseline and forced-full each require exactly
`{"fullCrawl":1}`, projected requires exactly `{"diffSeedServing":1}`, and
every cohort requires an empty fallback map. Configured route names alone never
satisfy the gate.

## Sample records

Each sample records correlation-scoped:

- p50/p95 materialize-to-root-ready, first-search completion, and first-read
  completion;
- first search/read tool duration;
- configured and actual route plus every fallback reason;
- Git command count, family, priority, duration, and queue wait;
- filesystem operation/item/duration counts and codemap attribution;
- process CPU, average/peak core utilization, peak and retained resident memory,
  and peak and retained physical footprint;
- content oracles, receipt ambiguity/eviction, and cleanup state.

## Smoke lane checks

The smoke lane uses a script-owned app worktree and temporary roots. It checks:

- the active parent makes exactly 20 calls, alternating ten `file_search` and
  ten `read_file` calls against the tracked marker, then returns exactly
  `RPCE_ACTIVE_PARENT_OK`. Its transcript rejects Bash/shell/exec, delegation,
  any other substitute tool, missing/extra/reordered invocations or paired
  result events, explicitly unsuccessful statuses, or a missing final sentinel.
  `agent_manage.get_log` intentionally emits spartan self-closing result events,
  so the harness does not claim unavailable result payload/status proof; terminal
  `completed` plus the exact sentinel is the available completion evidence;
- a nested child started from the parent context has the exact parent session
  and inherited worktree. The child start is an atomic CLI bind+call explicitly
  routed to the parent context; the child must return a distinct context UUID
  and exactly the same inherited worktree binding ID/path set as the parent.
  Its spartan transcript must contain one ordered `file_search` plus `read_file`
  invocation/result pair, terminal `completed`, and the exact final sentinel;
- every smoke CLI invocation atomically binds its requested context and records
  exactly two JSON documents in order—binding, then final raw tool result—and
  rejects missing, extra, or reordered documents. Validators accept the
  current successful raw shapes (`content_match_groups`, `display_path`,
  selection `files[].root_path/path_within_root`, and code-structure
  `files/issues/summary`) while requiring tool success, the exact bound root,
  exact requested/returned paths, marker content, and no unexpected cross-root
  files (same-root related codemaps are permitted);
- relative result paths require explicit per-file root metadata, a unique root
  prefix, or a single-root atomic binding. Ambiguous roots—including distinct
  roots sharing a basename—and otherwise unattributed relative paths fail;
- selection and explicit/selected `get_code_structure` use runtime root
  UUID/path/type evidence plus binding and per-file root/path evidence to
  exclude cross-root/non-Git substitutions;
- main/worktree/non-Git marker searches do not leak across explicit root filters;
- non-Git search/read work and codemap returns an explicit typed unavailable
  status and issue code rather than a
  graph from another root, with exactly one attributed `get_code_structure`
  work record and zero Git commands;
- watcher create, edit, rename, and delete converge via bounded polling of
  successful exact-binding raw search records;
- before, during, and after every ordinary/linked-worktree add/remove, the
  parent remains `running` on the identical context and the during-poll overlaps
  the mutation interval;
- added roots appear in the exact workspace inventory and pass search/read,
  selection, and codemap checks; removed roots disappear from inventory and
  revoke search/read/selection/codemap state;
- add/remove overlaps at least one in-flight `file_search`, `read_file`,
  selection, or `get_code_structure` subprocess call, rather than claiming a
  race from calls that already completed;
- removed-root search must succeed with zero matches/files searched, selection
  must omit the removed root, and code structure must succeed with
  `status:unavailable` plus `path_not_found`; all are checked against an atomic
  binding that must no longer contain the exact former Git root and an explicit request
  path under that root. `read_file` currently reports removal as an invalid-params
  error, so only the exact former path plus the explicit “not inside any loaded
  folder” rejection is accepted. Generic or mismatched failures are rejected,
  and the surviving root must still succeed through exact binding/path evidence.
  The separate non-Git codemap check instead requires the current non-Git root
  remain present in the binding with typed `git_root_unavailable` evidence.

## Resumed cleanup and the memory sampler

Resumed cleanup treats `state.json` resource IDs as selectors, never as ownership
proof. It does not use `agent_manage.list_sessions`, request per-worktree status,
or depend on any inventory limit. It first reads the cheap status-free worktree
inventory, then uses the exact benchmark correlation/control record to recover
the server-known session, target tab, repository, worktree, branch, head, binding,
phase, and physical-path digest. Logical unbind/release and a zero-count
session-specific store-drain snapshot are mandatory before physical deletion.
The final status-free inventory and drain snapshot must remain clear. Missing or
ambiguous identity, timeouts, nonterminal agents, shared roots, open watchers,
queued/applying publications, dirty worktrees, or nonzero drain counts cause no
physical deletion; the action is reported as manual cleanup.

The DEBUG memory sampler returns an immutable `session_id`, rejects every
occupied `start` (including requests that contain legacy `reset:true`), refuses
`reset` while active, and accepts `stop` only for the matching live ID. Normal
teardown stores and stops that exact ID. Resumed cleanup first proves the live
`current.session_id` and label match the recorded artifact, then conditionally
stops that ID; a foreign, missing, failed, or ambiguous session is preserved for
manual cleanup. A stale state-file flag is not accepted. A proven worktree is
removed only after all recorded agents are terminal/cancelled.

## `codemap-gate` pass criteria

The command passes only when all of these gates pass:

1. There are exactly the configured counts (minimum 20 cold and 40 warm) for both the
   individual-file and directory cohorts. Every cold file must first prove
   absence of its exact codemap `+` marker through a non-demanding tree probe;
   warm repetitions reuse those same cold fixtures. All requests use the
   server-owned fixed 10-second readiness deadline. Before live work begins,
   the harness saves `rpce-cli-debug describe get_code_structure` and fails
   immediately if the model-facing schema advertises a caller-controlled
   readiness deadline; no harness or agent request may tune that deadline.
2. Every successful structure request is exactly `ready`, contains the expected
   real codemap marker and a content hash at the current logical path, and is
   followed by an atomically same-context tree request bound to the exact root,
   requested direct parent, full reconstructed logical file path, `+` marker and
   `(+ denotes code-map available)` legend. `partial`/`pending` or a
   readiness-derived subset fails.
3. One small, fail-fast real `agent_run` probe covers two individual files and
   two directories, followed by the inherited-worktree child and concurrent
   ordinary/linked agents; this is not a large inference/stress loop. Raw
   transcripts prove ordered call/result pairs and forbid caller-controlled
   readiness limits.
   Every agent also has exact monotonic timings and structured content/path/tree
   evidence. If transcript result events are spartan, the harness performs the
   exact structure/tree probes atomically in that same session context/worktree
   and records the session-context-binding correlation. Any Bash, shell,
   exec, command, delegation, substitute encoding, unexpected tool, missing
   result, reordering, or wrong final sentinel fails. Spartan self-closing agent
   result events are invocation evidence only and never borrow evidence from an
   unrelated cohort.
4. The primary root continues serving structure while a script-owned secondary
   linked-worktree root is added and removed. A root-targeted DEBUG hold keeps
   the linked-root agent itself running immediately before removal. After
   removal, that exact session/context must terminalize or be cancelled and an
   atomic probe of its old full path must return typed empty revocation with the
   linked root absent from binding and no primary/cross-root fallback.
5. Non-Git search/read succeeds, structure is typed terminal, and the scoped
   build/projection/catalog counters remain unchanged. Watcher
   create/edit/rename/delete publishes only current structure and markers.
   Strict directory overflow returns empty `budget`, `attempted:2`, `limit:1`,
   and zero downstream build/projection/catalog demand.
6. Every directly timed server `get_code_structure` request in raw CLI evidence
   terminates within the 10,000 ms server wait plus 500 ms harness allowance;
   agent calls additionally require ordered paired results and terminal success.
   The held timeout itself must occur within 10,000 ms ± 500 ms and
   report `attempted` in that same band with `limit:10000`; these values come
   from the internal fixed default, never a request field. An immediate mocked
   timeout fails. The DEBUG-only token-owned hold pauses only future projection
   batch admission, auto-expires, and must produce an empty typed `timeout` with
   `readiness_timeout`, issue-level and reply-level retry metadata. Releasing
   the exact hold followed by retry must produce current `ready` content.
7. The baseline must have the exact metric, gate, privacy, configuration, and
   sample inventories; every required p50/p95 is finite and positive, every
   gate passes, privacy is complete, and the separate acceptance-ledger digest
   matches. Separate p50/p95 distributions are present for cold/warm individual
   structure, cold/warm directory structure, tree-marker availability, first
   search, first read, root readiness, projection queue wait, operation
   duration, and memory deltas. Root/search/read p95 and warm structure p50/p95
   may regress no more than 10% from the retained baseline; memory-delta p95
   uses the same fail-closed 10% ceiling.
8. No projection budget/resource counter is exceeded, no byte counter
   saturates, all holds are released or proven expired, only script-owned roots,
   files, agents, and worktrees are removed, memory sampling is stopped, the
   benchmark setting is unchanged, and the workspace returns to its sole
   planned root. Interrupted Git-root removal additionally requires successful
   live `cleanup_worktree_ownership_evidence`; non-Git removal requires its live
   artifact/plan/token-bound marker. Cleanup directly proves every recorded
   session and has no 1,000-session cap.

## Content-addressed codemaps production-enable gate

This is the gate the content-addressed codemaps campaign used. Plans written
today freeze a 30% projected p95 improvement and a 10% ceiling on other
regressions, and the aggregate applies the plan's values.

The production-enable gate is all-or-nothing:

1. zero file/folder/search/read/selection/codemap/watcher/root-lifecycle
   correctness mismatches;
2. zero eligible projected fallbacks after warmup;
3. projected p95 improves at least 40% over forced-full for root-ready,
   first-search, and first-read;
4. every other latency p95 regresses no more than 5%;
5. absolute peak/final RSS and physical-footprint growth are each no more than
   10%, including width 8 and aged-app cohorts; signed deltas are report-only,
   and missing, zero, negative, or non-finite control baselines fail closed;
6. artifact IDs, cohort/invocation keys, sample ordinals, correlation UUIDs,
   and session UUIDs are unique, one-to-one, and cannot mix reruns; planned
   invocation and sample counts are exact;
7. every documented CPU/RSS, Git, filesystem, actual-route, and fallback field
   is present and valid: availability is explicit; counts are nonnegative
   integers; Git family and priority totals equal command count; filesystem
   operation/item counts and duration are typed and internally consistent;
   RSS/physical-footprint absolutes are positive finite values with coherent
   peaks/deltas; CPU totals, sample count, duration, and average/peak core
   utilization are finite, ranged, and internally consistent;
8. teardown evidence is complete: agents terminal, secondary roots/worktrees
   removed, memory sampling stopped and independently verified, route/settings
   restored or unchanged, diagnostics reset, and the sole planned root restored.
