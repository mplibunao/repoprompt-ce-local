# Catalog shard batch patch: measurements for #222

> Investigation report, observed 2026-10-20 on debug apps built from branch `bugfix/222-catalog-shard-batch-patch`. It records what was true then. Where it disagrees with a current document, the current document is right.

## Findings

- **Measurement and cap.** On generated roots of 10,000, 35,000, and 100,000 files, patching a batch of up to 4,096 effective edits was faster than rebuilding the root's catalog shard for every measured shape and size, and every patched shard matched the rebuilt one. No crossover appeared, so the cap of 4,096 is a lower bound on where patching stops paying off.
- **Cost by batch and root.** The batch-dependent phases of a patch take the same time at all three root sizes. With the materialized path index these runs used, the timed part that still grows with the root is the merge copy: medians of 0.62, 2.21, and 7.28 ms at 10,000, 35,000, and 100,000 files. The copy at 550,000 files and the projected path index's scaling weren't measured.
- **Copy-on-write ingress.** Before the fix that changes root state in place during ingress (section 3), the store's ingress cost per added file grew with the root, from about 176 µs at 10,000 files to 996 µs at 100,000. After it, the cost was flat between those sizes.
- **#213 reproduction.** No shard rebuild ran, and the shard patch took 2% of the store actor's time. The applied rate still fell, from 0.96 to 0.29 publications per second, because other work that reads the whole root on each change kept the store actor busy for nearly all of a 7.6 s sample. The reproduction reached about 185,000 applied files, not 550,000.
- **Multi-root load test.** Every root's apply P95 was at most 13.1 ms, no root built a backlog, and the longest store-actor job was 67 ms. 169 of 4,302 reads and 122 of 868 searches failed, all with a domain-routing conflict in the MCP layer that this change doesn't touch.

## Terms

- **Catalog shard:** a root's sorted file, folder, and search-entry arrays in the workspace store, with its path index.
- **Publication:** one batch of file changes that the file watcher publishes after its scheduled coalescing delay of 0.2 s from a burst's first event. A longer burst can arrive as more than one publication.
- **Effective edits:** a batch's file and folder record insertions plus removals in the shard, so a record that replaces another at the same path counts two. A modification of an existing file doesn't change any record, so it isn't an effective edit. The cap gates patch eligibility. A batch over the cap, or one the store can't patch safely, requests an authoritative rebuild instead. Retention can block publishing the patch or the rebuild, which leaves the shard dirty until a later build. A root with no published shard and no delta state for its current lifetime stays lazy whatever the batch size.
- **Patch:** applying a batch to the existing shard. Its time here is the timed-phase total, the sum of five DEBUG-timed phases: normalize, locate, derive, merge copy, and path-index segment. The total leaves out building `affectedFileIDs`, `changedRelativePaths`, and the patch payload, which runs after the merge-copy phase and before the path-index segment. It also leaves out publishing the patched shard, as the rebuild time leaves out installing its shard. The batch-dependent phases are all of the timed phases except the merge copy.
- **Merge copy:** the patch's one copy of each shard array that has edits. Its cost grows with the root.
- **Rebuild:** building the root's shard from its current records, which the store requested for every batch with more than one effective edit before #222. The DEBUG comparison mode builds one after a patched batch, times it, and checks that it equals the patched shard (parity).
- **Canonical apply:** the time from entering `applyPreparedIndexDeltas` to the end of the mutation pass, minus comparison time. It includes the preflight's awaited eligibility checks and any wait to resume on the store actor after them. It excludes the eligibility loop in `handleObservedFileSystemDeltas` and the wait to enter the store actor, so it isn't end-to-end publication latency. The **mutation pass** is its last part, the synchronous pass on the actor that applies the batch.
- **Outstanding publications:** publications the watcher has accepted and the store hasn't applied. A growing count is an ingress backlog.
- **Rebase flight:** a path-index base build that runs off the store actor. Patches made while it runs accumulate as overlays on the current path index.

## 1. Setup

**Builds.** All runs used debug apps on an arm64 Mac running macOS 26.6.

- The matrix ran on a build of the branch through `fix(workspace): rebase the path index off the store actor and walk folder subtrees`, plus uncommitted documentation-only changes. Between that commit and the later build, the store's changes were in ingress, root-state access, folder removal, and DEBUG diagnostics. Inside `buildRootCatalogShardPatch` only a DEBUG input counter was removed, and `mergeRootCatalogShards` didn't change, so the matrix measured the patch code the later runs used.
- The copy-on-write re-measure in section 3, the #213 reproduction, and the multi-root load test ran on a build of the branch through `docs: record the issue 222 review rounds in the run ledger`, with the release cap set to 4,096 in the working tree.
- Another window held a workspace of this repository throughout, unrelated to the measurements.

**Diagnostics.** The DEBUG `mcp_read_search_runtime_snapshot` diagnostic returned per-batch samples (`catalog_batch_sample_limit`), raised the cap for the matrix (`catalog_patch_cap_override`), and armed the comparison (`catalog_patch_comparison`). [`docs/testing.md`](../testing.md#catalog-shard-patch-measurement) describes those arguments. macOS `sample`, `footprint`, and `heap` recorded process samples, memory footprint, and heap object counts.

**Matrix roots.** Three generated roots of one-line files, with 10,010, 35,010, and 100,010 files. Each holds a `gen/` folder with 50, 175, or 500 folders of 200 files, and a `nest/` folder with eight chains of folders six levels deep. The deepest file is seven path components deep.

**Shapes.** Batch sizes were 1, 4, 16, 64, 201, 1,024, and 4,096.

- **Adds across folders:** the batch's files are renamed into existing `gen/` folders, spread over at most 64 folders.
- **Adds into nested folders:** the batch's files are renamed into the eight deepest `nest/` folders. Each add also upserts its unchanged ancestor folders, which the patch counts as no-ops.
- **Subtree removals:** a folder holding the batch size minus one files is renamed out of the root, so the batch removes that many files plus the folder.
- **In-place modifications:** the batch's files are rewritten in place. These carry no effective edits, so the cap never applies to them. They're reported but kept out of the cap rule.

**How batches were driven.** Each attempt went through these steps:

1. One diagnostic call raised the cap override above the batch size and armed the comparison for the next batch.
2. The batch was written in one burst. Adds were staged outside the root and renamed in, because a rename takes about 25 µs and 4,096 of them fit inside the 0.2 s coalescing delay, which 4,096 file creates barely do.
3. The run waited for ingress to drain.
4. With the comparison off, the batch was reversed, so the root kept its size.

Each cell ran three warm-up attempts and then ten measured ones, except six modification cells, which ran 12, 14, or 20. An attempt was valid when one batch sample held all of its effective edits, with outcome `patched`, no fallback reason, effective edits equal to the batch size, and a comparison. Parity was recorded as an outcome, not used to exclude an attempt. An attempt wasn't rejected for arriving as more than one publication. The matrix took each attempt's new samples by applied-index generation and didn't use `dropped_count`. For every attempt, the observed-sample count rose by no more than the number of new samples returned.

## 2. The matrix

The matrix has 84 cells and 886 measured attempts, after 252 warm-ups. No add or removal attempt was excluded, and parity matched in every attempt.

- The input of an add counts its ancestor upserts: 3 per add across folders and 7 per nested add, so a 4,096-file add carried 12,288 or 28,672 inputs for 4,096 effective edits.
- Add bursts of 1,024 and 4,096 files often arrived as two publications. In every valid attempt only one of them carried effective edits.
- Rewriting 1,024 or 4,096 files took longer than the coalescing delay, so the measured batch held fewer modifications than files rewritten (77 attempts). The modification table lists the median count the store received.

Times are in milliseconds, and patch times are the timed-phase total. "Root files" is the root's size before the batch, and the median ratio is the patch median over the rebuild median.

**Adds across folders**

| Root files | Effective edits | Patch median | Patch P95 | Rebuild median | Rebuild P95 | Median ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 1 | 0.87 | 1.14 | 202 | 211 | 0.00 |
| 10,000 | 4 | 1.10 | 1.28 | 203 | 214 | 0.01 |
| 10,000 | 16 | 2.23 | 2.76 | 202 | 216 | 0.01 |
| 10,000 | 64 | 8.99 | 11.1 | 203 | 236 | 0.04 |
| 10,000 | 201 | 12.6 | 13.5 | 191 | 198 | 0.07 |
| 10,000 | 1,024 | 40.0 | 44.6 | 218 | 238 | 0.18 |
| 10,000 | 4,096 | 145 | 160 | 300 | 324 | 0.48 |
| 35,000 | 1 | 3.01 | 4.61 | 603 | 629 | 0.00 |
| 35,000 | 4 | 4.15 | 12.5 | 697 | 779 | 0.01 |
| 35,000 | 16 | 3.99 | 5.06 | 684 | 837 | 0.01 |
| 35,000 | 64 | 9.80 | 11.1 | 596 | 651 | 0.02 |
| 35,000 | 201 | 14.8 | 17.1 | 616 | 944 | 0.02 |
| 35,000 | 1,024 | 43.1 | 44.5 | 676 | 687 | 0.06 |
| 35,000 | 4,096 | 153 | 229 | 763 | 1,194 | 0.20 |
| 100,000 | 1 | 8.06 | 9.77 | 1,947 | 2,042 | 0.00 |
| 100,000 | 4 | 7.33 | 8.53 | 1,863 | 1,900 | 0.00 |
| 100,000 | 16 | 8.54 | 10.0 | 1,881 | 1,980 | 0.00 |
| 100,000 | 64 | 14.8 | 16.6 | 1,872 | 1,946 | 0.01 |
| 100,000 | 201 | 21.5 | 24.8 | 1,896 | 1,978 | 0.01 |
| 100,000 | 1,024 | 46.7 | 73.1 | 1,947 | 2,037 | 0.02 |
| 100,000 | 4,096 | 159 | 198 | 2,028 | 2,141 | 0.08 |

**Adds into nested folders**

| Root files | Effective edits | Patch median | Patch P95 | Rebuild median | Rebuild P95 | Median ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 1 | 1.36 | 1.74 | 184 | 200 | 0.01 |
| 10,000 | 4 | 3.31 | 5.08 | 181 | 214 | 0.02 |
| 10,000 | 16 | 4.52 | 6.88 | 186 | 234 | 0.02 |
| 10,000 | 64 | 5.50 | 5.88 | 174 | 178 | 0.03 |
| 10,000 | 201 | 9.82 | 10.9 | 174 | 190 | 0.06 |
| 10,000 | 1,024 | 31.5 | 35.3 | 187 | 200 | 0.17 |
| 10,000 | 4,096 | 118 | 138 | 253 | 269 | 0.47 |
| 35,000 | 1 | 2.52 | 3.03 | 642 | 671 | 0.00 |
| 35,000 | 4 | 3.50 | 3.84 | 651 | 667 | 0.01 |
| 35,000 | 16 | 7.76 | 12.9 | 741 | 772 | 0.01 |
| 35,000 | 64 | 7.82 | 10.9 | 639 | 720 | 0.01 |
| 35,000 | 201 | 12.7 | 18.8 | 677 | 753 | 0.02 |
| 35,000 | 1,024 | 39.1 | 42.9 | 714 | 746 | 0.05 |
| 35,000 | 4,096 | 137 | 179 | 774 | 838 | 0.18 |
| 100,000 | 1 | 7.59 | 9.86 | 1,913 | 2,209 | 0.00 |
| 100,000 | 4 | 9.47 | 14.3 | 2,022 | 3,835 | 0.00 |
| 100,000 | 16 | 11.5 | 35.0 | 1,997 | 2,731 | 0.01 |
| 100,000 | 64 | 13.0 | 15.4 | 1,909 | 2,002 | 0.01 |
| 100,000 | 201 | 17.6 | 20.8 | 1,914 | 2,485 | 0.01 |
| 100,000 | 1,024 | 42.3 | 315 | 2,136 | 6,045 | 0.02 |
| 100,000 | 4,096 | 170 | 618 | 2,335 | 11,345 | 0.07 |

**Subtree removals**

| Root files | Effective edits | Patch median | Patch P95 | Rebuild median | Rebuild P95 | Median ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 1 | 0.09 | 0.15 | 183 | 193 | 0.00 |
| 10,000 | 4 | 1.13 | 1.97 | 182 | 189 | 0.01 |
| 10,000 | 16 | 1.33 | 3.50 | 181 | 200 | 0.01 |
| 10,000 | 64 | 2.63 | 4.26 | 181 | 193 | 0.01 |
| 10,000 | 201 | 4.97 | 5.64 | 174 | 183 | 0.03 |
| 10,000 | 1,024 | 14.8 | 15.1 | 168 | 185 | 0.09 |
| 10,000 | 4,096 | 63.6 | 68.4 | 165 | 173 | 0.38 |
| 35,000 | 1 | 0.06 | 0.12 | 669 | 862 | 0.00 |
| 35,000 | 4 | 2.22 | 3.71 | 635 | 665 | 0.00 |
| 35,000 | 16 | 2.24 | 2.61 | 630 | 667 | 0.00 |
| 35,000 | 64 | 3.13 | 4.52 | 652 | 697 | 0.00 |
| 35,000 | 201 | 5.18 | 5.87 | 695 | 787 | 0.01 |
| 35,000 | 1,024 | 18.6 | 23.5 | 672 | 754 | 0.03 |
| 35,000 | 4,096 | 70.7 | 77.9 | 627 | 640 | 0.11 |
| 100,000 | 1 | 0.09 | 0.26 | 2,402 | 3,494 | 0.00 |
| 100,000 | 4 | 8.51 | 11.8 | 2,092 | 2,726 | 0.00 |
| 100,000 | 16 | 7.57 | 10.8 | 1,906 | 1,967 | 0.00 |
| 100,000 | 64 | 9.05 | 26.8 | 1,892 | 2,082 | 0.00 |
| 100,000 | 201 | 13.1 | 26.3 | 2,013 | 2,606 | 0.01 |
| 100,000 | 1,024 | 28.4 | 60.0 | 2,008 | 2,645 | 0.01 |
| 100,000 | 4,096 | 78.6 | 108 | 1,990 | 2,591 | 0.04 |

**In-place modifications (outside the cap rule)**

| Root files | Files rewritten | Modifications in the batch (median) | Patch median | Patch P95 | Rebuild median | Rebuild P95 |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 1 | 1 | 0.12 | 0.20 | 204 | 337 |
| 10,000 | 4 | 4 | 0.23 | 0.45 | 196 | 210 |
| 10,000 | 16 | 16 | 0.74 | 0.86 | 192 | 194 |
| 10,000 | 64 | 64 | 1.55 | 1.83 | 180 | 186 |
| 10,000 | 201 | 201 | 3.05 | 3.18 | 169 | 231 |
| 10,000 | 1,024 | 1,015 | 11.8 | 12.7 | 167 | 172 |
| 10,000 | 4,096 | 2,278 | 26.5 | 29.6 | 172 | 200 |
| 35,000 | 1 | 1 | 0.08 | 0.10 | 635 | 656 |
| 35,000 | 4 | 4 | 0.11 | 0.23 | 645 | 780 |
| 35,000 | 16 | 16 | 0.29 | 0.72 | 636 | 782 |
| 35,000 | 64 | 64 | 1.08 | 2.29 | 645 | 699 |
| 35,000 | 201 | 201 | 3.05 | 3.48 | 620 | 643 |
| 35,000 | 1,024 | 1,024 | 14.6 | 17.3 | 604 | 638 |
| 35,000 | 4,096 | 2,464 | 33.6 | 36.0 | 599 | 623 |
| 100,000 | 1 | 1 | 0.06 | 0.12 | 2,413 | 3,794 |
| 100,000 | 4 | 4 | 0.11 | 0.16 | 1,902 | 1,968 |
| 100,000 | 16 | 16 | 0.34 | 0.73 | 1,905 | 2,042 |
| 100,000 | 64 | 64 | 1.23 | 2.89 | 1,974 | 2,887 |
| 100,000 | 201 | 201 | 3.61 | 4.32 | 2,080 | 2,299 |
| 100,000 | 1,024 | 1,024 | 16.9 | 27.3 | 1,978 | 2,141 |
| 100,000 | 4,096 | 2,088 | 36.7 | 43.5 | 2,001 | 2,447 |

The nested-add cells at 100,000 files and 1,024 or 4,096 edits had high P95s on both sides: 315 and 618 ms for the patch, 6.0 and 11.3 s for the rebuild.

### The cap rule and the chosen cap

The cap is the largest batch size in the contiguous passing range where, at 35,000 and 100,000 files and for adds across folders, nested adds, and subtree removals:

- the patch median is at most 80% of the rebuild median;
- the patch P95 doesn't exceed the rebuild P95;
- parity passes.

Every measured size passed, so the release cap (`maxRootCatalogShardPatchLogicalMutationCount` in `Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift`) is 4,096, the largest size measured. No cell above 4,096 was measured, and the rule doesn't extrapolate, so 4,096 is a lower bound on where patching stops paying off. With no crossover, the crossover can't be expressed as a fraction of root size either: 4,096 edits are 41%, 11.7%, and 4.1% of the three roots.

At 4,096 edits:

| Root files | Shape | Median ratio | Patch P95 | Rebuild P95 |
|---:|---|---:|---:|---:|
| 10,000 | Adds across folders | 0.48 | 160 | 324 |
| 10,000 | Nested adds | 0.47 | 138 | 269 |
| 10,000 | Subtree removals | 0.38 | 68.4 | 173 |
| 35,000 | Adds across folders | 0.20 | 229 | 1,194 |
| 35,000 | Nested adds | 0.18 | 179 | 838 |
| 35,000 | Subtree removals | 0.11 | 77.9 | 640 |
| 100,000 | Adds across folders | 0.08 | 198 | 2,141 |
| 100,000 | Nested adds | 0.07 | 618 | 11,345 |
| 100,000 | Subtree removals | 0.04 | 108 | 2,591 |

The 10,000-file root isn't part of the rule. It passes the same conditions at 4,096 edits, a batch of 41% of the root.

### What grows with the batch and what grows with the root

Medians of the batch-dependent phases (normalize, locate, derive, and path-index segment), summed per attempt, in milliseconds:

| Shape | Effective edits | 10,000 files | 35,000 files | 100,000 files |
|---|---:|---:|---:|---:|
| Adds across folders | 1 | 0.26 | 0.32 | 0.28 |
| Adds across folders | 64 | 8.32 | 7.57 | 8.17 |
| Adds across folders | 201 | 12.1 | 12.5 | 13.4 |
| Adds across folders | 1,024 | 39.4 | 40.3 | 39.3 |
| Adds across folders | 4,096 | 143 | 148 | 145 |
| Nested adds | 1 | 0.60 | 0.44 | 0.52 |
| Nested adds | 64 | 4.98 | 5.44 | 5.50 |
| Nested adds | 201 | 9.32 | 9.96 | 9.40 |
| Nested adds | 1,024 | 30.8 | 35.4 | 32.8 |
| Nested adds | 4,096 | 116 | 134 | 145 |
| Subtree removals | 1 | 0.08 | 0.05 | 0.06 |
| Subtree removals | 64 | 1.66 | 0.80 | 0.81 |
| Subtree removals | 201 | 4.10 | 2.80 | 2.82 |
| Subtree removals | 1,024 | 14.1 | 16.0 | 16.1 |
| Subtree removals | 4,096 | 62.4 | 66.8 | 69.3 |

These phases grow with the batch and stay within 1.25 times their 10,000-file time at 100,000 files.

Merge copy, over all patched attempts:

| Root files | Attempts | Median ms | P95 ms | Elements copied (median) |
|---:|---:|---:|---:|---:|
| 10,000 | 300 | 0.62 | 1.78 | 20,052 |
| 35,000 | 294 | 2.21 | 6.11 | 70,052 |
| 100,000 | 292 | 7.28 | 24.9 | 200,052 |

The merge copy costs about 31 to 36 ns per copied element. It runs on the store actor, and it's the only timed phase that grows with the root in the materialized path index these runs measured. Every batch that changed the path index added an overlay segment, which only the materialized index records. At 100,000 files the merge copy is the largest part of the timed-phase total below about 64 effective edits for adds across folders, 201 for nested adds, and 1,024 for subtree removals. Modifications don't copy. The copy at 550,000 files wasn't measured, because the #213 reproduction didn't apply a root that large.

A root whose path index is projected from a seeded snapshot takes a different route. The projected index's patch initializer (`WorkspaceProjectedPathSearchIndex` in `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift`) checks every authoritative entry with `allSatisfy` and filters every entry for the changed paths, so its cost grows with the root. These runs didn't measure how that route scales.

## 3. Copy-on-write ingress cost

Ingress cost per added file is the batch sample's `ingress.added_file_us` divided by its added-file count. Medians in µs from the matrix, before `fix(workspace): change root state in place during ingress`, ten batches per cell:

| Shape | Added files | 10,000 files | 35,000 files | 100,000 files |
|---|---:|---:|---:|---:|
| Adds across folders | 201 | 176 | 343 | 996 |
| Adds across folders | 1,024 | 178 | 359 | 994 |
| Adds across folders | 4,096 | 182 | 376 | 1,010 |
| Nested adds | 201 | 243 | 484 | 1,385 |
| Nested adds | 1,024 | 245 | 504 | 1,360 |
| Nested adds | 4,096 | 253 | 488 | 1,940 |

The cost per file grew roughly in proportion to the root. Each ingress mutation copied the root's `RootState`, changed the copy, and wrote it back, and the copy shared storage with the stored state, so the first change copied every root-sized index it touched. The commit `fix(workspace): change root state in place during ingress` changes the stored state in place.

The same cells, re-measured on the later build, ten batches per cell:

| Shape | Added files | 10,000 files | 100,000 files | 100,000 / 10,000 |
|---|---:|---:|---:|---:|
| Adds across folders | 201 | 145 | 98 | 0.68 |
| Adds across folders | 1,024 | 119 | 125 | 1.05 |
| Adds across folders | 4,096 | 109 | 113 | 1.04 |
| Nested adds | 201 | 232 | 222 | 0.96 |
| Nested adds | 1,024 | 224 | 206 | 0.92 |
| Nested adds | 4,096 | 247 | 192 | 0.78 |

At 100,000 files, the mutation pass for 4,096 nested adds fell from a median of 8.2 s and a maximum of 25.3 s to a median of 1.06 s and a maximum of 1.23 s. The #213 reproduction agrees: 149 µs per added file near 10,000 files and 171 µs near 100,000.

## 4. The #213 reproduction

The run followed #213's procedure on a generated root with an empty generated area:

- every 0.1 s, a new folder of 200 one-line files;
- every 2 s, deletion of the oldest generated folder;
- the generator ran until about 2,750 folders existed (about 550,000 files), which took 363 s.

A reader in a second, idle root read a one-line file every 2 s and called the runtime snapshot every 5 s. Every 30 s, a probe searched for the newest finished folder, which must be found, and the most recently deleted one, which must be absent. The release cap was 4,096 and the comparison was off.

One of three planned runs was made. The other two weren't, because gate 4 failed for a cause outside the patch. The run was stopped 912 s after it started, 519 s after the generator finished. At that point the store had applied a root of 185,344 files, 194 publications were outstanding, and the oldest was 736 s old. No batch sample came from a root above 180,201 files, so every gate's 550,000-file data is missing.

Each gate is a pass condition set before the run.

| Gate | Verdict | Measurement |
|---|---|---|
| 1(a) Batch-dependent phases at 100,000 and 550,000 files at most 2× those at 10,000 | Pass at 100,000; no 550,000 data | Only the 701–1,000-edit bucket had at least 5 batches at both sizes (6 and 6): median ratio 1.41, P95 ratio 0.99. Buckets with fewer batches had ratios from 0.36 to 1.44. |
| 1(b) Whole apply at 550,000 files: median ≤ 50 ms, P95 ≤ 200 ms | No verdict | Canonical apply median and P95: 328 and 670 ms near 10,000 files (16 batches), 677 ms and 4.6 s near 100,000 (46 batches), maximum 6.6 s. These include the preflight's awaited eligibility checks and waits to resume on the store actor. The mutation pass alone had medians of 151 and 114 ms and maxima of 289 and 730 ms. The merge copy had a 0.76 ms median (15,122 elements) near 10,000 files, and a 17.9 ms median and 53.9 ms P95 (199,250 elements) near 100,000. |
| 2 No root-sized work on the actor below the cap | No full rebuild or full path-index build on the actor; the root-sized merge copy remains | All 318 sampled batches patched; the largest carried 3,618 effective edits. No shard rebuild, full path-index build on the actor, authoritative rebuild, or uncached snapshot build. Each patch that changed a shard array still ran the merge copy on the actor. |
| 3 Subtree removals scale with descendants | No verdict | 2 removals near 10,000 files and 10 near 100,000: 25 and 42 µs per removed record. The run's 69 removals visited 195.8 records each on average, close to the 201 records (200 files and the folder) in each removed folder. |
| 4 No backlog growth | **Fail** | Outstanding publications: P90 of 193 in the run's first third and 303 in its last, slope 0.80 per second, maximum 306. Applied publications per second by minute: 0.96, 0.49, 0.56, 0.60, 0.56, 0.42, 0.29. The backlog never drained. |
| 5 Convergence | **Fail** | All 18 probes timed out at the 30 s freshness wait, including the two taken while path-index overlays were in their top tenth by size (16,800 mentions or more). The end-of-run comparison was never reached. |
| 6 Memory | No verdict | One run only, and the root never drained. Footprint 2.29 GB at the stop, process peak 2.52 GB. At most 2 live shard generations per root. A rebase was in flight at the stop. No footprint series was recorded during the run. |
| 7 Pre-wait store calls | Pass | 268 reads: none timed out, detached before its freshness wait, or returned wrong content. Read time maximum 11.4 s. For the 91 reads matched to the read lifecycle capture, the time from receiving the call to entering the read provider reached at most 5.8 s. Runtime snapshot calls reached 12.1 s. Longest mutation pass 1.43 s. No store-actor job exceeded the 5 s cancellation grace. |
| 8 Rebase duty cycle at 550,000 files ≤ 50% | No verdict | 39% of wall time over the generator run. 35 flights, 34 installs, no discards. Longest build 61.5 s. Peak overlays: 27 payloads and 20,800 mentions. |

In #213's original run, before this change, the applied rate fell from about 0.2 to 0.06 publications per second, and the drain samples were dominated by the authoritative shard rebuild: 968 of 1,048 samples. Here no rebuild ran and the rate started about five times higher, but it fell by the same factor of about 0.3.

### Store-actor saturation

These shares come from one 7.6 s process sample at 1 ms intervals, taken while the backlog grew and the applied root held about 180,000 files. The sample holds 7,616 samples under store-actor entry points in 7,597 ms. Those samples include the awaited eligibility checks described below, so the store actor itself was busy for slightly less than the whole sample.

| Store-actor work | Called from | Samples | Share |
|---|---|---:|---:|
| Ingress: the mutation pass and its preflight | `WorkspaceFileSystemIngressCoordinator.drain` | 2,104 | 28% |
| A sorted copy of every file record in the root (`files(inRoot:)`) | `TokenCountingViewModel.allStoreFileRecords` | 1,589 | 21% |
| The file-tree presentation (`makeFileTreePresentation`) | Prompt statistics (811) and the prompt's file-tree content (714) | 1,525 | 20% |
| A search catalog merged from every shard (`searchCatalogSnapshot`) | `WorkspaceSearchService.rebuildFromStoreIfCurrent` | 1,248 | 16% |
| The file panel's sorted root snapshot (`appliedIndexRootSnapshot`, which calls `files(inRoot:)`) | `WorkspaceFilesViewModel.handleHiddenSessionRootAppliedIndexEvent` | 1,077 | 14% |
| Other | | 73 | 1% |

Within ingress:

- 1,147 samples were per-file catalog-eligibility checks (`FileSystemService.catalogEligibleRegularFileExists`). `FileSystemService` is an actor, so each check is an await on the root's `FileSystemService` actor, not work on the store actor. The store's ingress drain waits on these checks one file at a time, twice per added file: first in `handleObservedFileSystemDeltas` through `isDiscoveryFacingFileSystemDelta`, then in `preflightPreparedIndexDeltas`. Their frames appear under the store's ingress entry points because the executor ran each callee inline on the same thread.
- The shard patch (`buildRootCatalogShardPatch`) took 178 samples, 2% of the actor's time.

A code read traced what starts these reads:

- Every applied-index event reaches `WorkspaceFilesViewModel`, whose `applyWorkspaceAppliedIndexEvent` invalidates its static snapshot and sends `fileSystemChangedPublisher`.
- `TokenCountingViewModel` then marks the selection, file tree, codemap, and settings dirty, and recounts after a 500 ms debounce. The recount calls `files(inRoot:)` for every loaded root and, when the file tree is included, builds the file-tree presentation over every loaded root.
- `handleHiddenSessionRootAppliedIndexEvent` runs on every event with no debounce, and takes its snapshot before it checks whether the root is a session worktree.
- The search service rebuilds about 50 ms after each catalog change.

Each of the four reads covers the whole root, so its cost per change grows with the root while the patch's doesn't.

The same sample showed whole-root work off the actor too:

- The main thread spent 2,612 of its 7,597 samples (34%) in `FileHierarchyIndex.ownedDescendantPaths`. The file panel's removed-subtree cleanup calls it, and it filters every file and folder path in the root on each removal batch.
- One utility thread spent the whole sample building a path-index rebase.

## 5. The multi-root load test

**Roots.** 34 generated roots with 66,122 files in total:

- a 27-root replica of a real multi-root workspace, matching its per-root file counts and maximum depths: 31,120 files, the two largest roots holding 10,224 and 9,670, most under 500;
- five worktree-sized roots of 2,500, 5,000, 7,500, 10,000, and 10,000 files;
- two idle roots of one file each.

**Windows.** The replica workspace was open in one window and again in a second window, as in upstream issue 1416's report. The worktree-sized roots were split across two more windows, each with one idle root.

**Churn, for 30 minutes:**

- Each worktree-sized root had 1 to 20 file rewrites every 2 to 5 s.
- Each worktree-sized root also had a create of 1 to 5 files, or a delete of earlier creates, every 10 s.
- Each worktree-sized root had a checkout-like burst of 200 to 500 changed files every 3 minutes.
- Three replica roots of 10,224, 2,626, and 1,072 files had 1 to 4 rewrites every 10 s.
- The other 24 replica roots and the idle roots didn't change.

**Readers.** In every window, a read of a one-line file in an idle root ran every 2 s, and a `file_search` for a fixed pattern ran every 10 s, alternating path and content mode. A runtime snapshot of each window ran every 10 s, and the process footprint was recorded every 30 s. A 60 s baseline came before the churn, and a 5-minute hold with the readers still running came after the drain. The release cap was 4,096 and the comparison was off.

### Gate 9

| Criterion | Verdict | Measurement |
|---|---|---|
| Every root's canonical apply P95 at most 200 ms, outside fallback rebuilds | Pass | Highest root P95 13.1 ms. Every batch patched, and no fallback rebuild ran. |
| No root's backlog grows | Pass | No root had an outstanding publication in any 10 s snapshot. Every root drained within 0.9 s after the churn stopped. |
| Every window's longest store-actor job under the 5 s grace | Pass | Longest mutation pass per window: 6.9 and 8.5 ms in the two replica windows, 44.6 and 67.0 ms in the worktree windows. Runtime snapshot calls: medians 316 to 392 ms, P95s 589 to 783 ms, maximum 1.74 s. |
| Every read and every `file_search` completes | **Fail** | 169 of 4,302 reads and 122 of 868 searches failed, every one with the routing conflict described below. No read timed out or returned wrong content, and no search timed out. |

Canonical apply per churned root, in milliseconds:

| Window | Root files | Batches | Median | P95 | Maximum |
|---|---:|---:|---:|---:|---:|
| Replica, first window | 10,224 | 180 | 0.65 | 2.20 | 6.69 |
| Replica, first window | 2,626 | 180 | 0.41 | 1.48 | 6.99 |
| Replica, first window | 1,072 | 181 | 0.37 | 0.77 | 2.29 |
| Replica, second window | 10,224 | 180 | 0.62 | 2.22 | 12.0 |
| Replica, second window | 2,626 | 180 | 0.43 | 1.46 | 8.80 |
| Replica, second window | 1,072 | 181 | 0.36 | 0.72 | 2.92 |
| Worktree window A | 2,500 | 688 | 0.86 | 7.59 | 128 |
| Worktree window A | 7,500 | 692 | 1.09 | 11.8 | 91.0 |
| Worktree window A | 10,000 | 682 | 1.08 | 10.7 | 187 |
| Worktree window B | 5,000 | 700 | 1.12 | 8.08 | 72.2 |
| Worktree window B | 10,000 | 680 | 1.18 | 13.1 | 77.1 |

Read and search times, for calls that succeeded:

- **Reads:** medians of 375 to 424 ms per window, P95s of 1.20 to 1.29 s, maximum 3.95 s.
- **Path searches:** median 1.05 s, P95 1.51 s, maximum 4.33 s.
- **Content searches:** median 6.30 s, P95 9.03 s, maximum 10.6 s.

### The routing conflict, outside this change

Every failure returned `Domain authority unavailable for read_file` (or `file_search`) `: routing_revision_mismatch`. Each CLI call opens a new MCP connection and binds it to its window's context:

- The bind is a compare-and-swap on one global routing revision, retried at most three times before the call fails (`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+DomainRouting.swift`).
- `DomainRoutingCoordinator` (`Sources/RepoPromptDomainRuntime/DomainRoutingCoordinator.swift`) advances that revision on every successful bind and every connection release.

With four windows of concurrent CLI calls, a call can lose all three attempts. Per window, failures were 1% to 6% of reads and 4% to 22% of searches, including some in the 60 s baseline before any churn. This change doesn't touch the routing code.

### Retained generations, uncached builds, and rebase activity

At the end of the run, roots held at most 2 live shard generations in the replica windows and 1 in the worktree windows. No window recorded an uncached authoritative snapshot build, so their size was 0 bytes.

Only the worktree-sized roots rebased their path indexes. Duty is build time over the churn's wall time:

| Root files | Flights | Installs | Discards | Build time (s) | Duty | Longest build (s) | Peak overlay payloads | Peak overlay mentions |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2,500 | 6 | 6 | 0 | 1.7 | 0.1% | 0.89 | 32 | 223 |
| 5,000 | 5 | 5 | 0 | 5.6 | 0.3% | 5.21 | 32 | 245 |
| 7,500 | 6 | 6 | 0 | 4.5 | 0.3% | 1.72 | 32 | 172 |
| 10,000 | 6 | 6 | 0 | 2.9 | 0.2% | 1.03 | 33 | 258 |
| 10,000 | 5 | 5 | 0 | 10.0 | 0.6% | 9.42 | 32 | 287 |

### Store actors under this load

These shares come from one 7.7 s process sample taken 15 minutes into the churn. Each window has its own store, so the sample's 6,076 samples under store entry points are spread across five store actors: the four test windows' and the unrelated workspace's.

- the token-counting sorted copy of the root: 1,744 (29%);
- content-search snapshots for the periodic searches: 1,284 (21%);
- the file-tree presentation: 999 (16%);
- MCP `file_search` store access: 769 (13%);
- the file panel's root snapshot: 671 (11%);
- the search catalog merge: 524 (9%);
- ingress: 57 (1%), of which the shard patch took 17.

The same whole-root reads that saturated the reproduction's store actor appear here. With roots of at most about 10,000 files they cost little: snapshot calls peaked at 1.74 s against 12.1 s in the reproduction, and the longest mutation pass was 67 ms against 1.43 s.

### Memory footprint

The process footprint rose from 1.78 GB at the start to 3.81 GB at its sampled peak. It measured 3.83 GB at the end of the 5-minute hold and 3.48 GB after the test's workspaces were removed. It grew at about 55 MB a minute, nearly all of it in small malloc allocations. It kept growing during the 5-minute hold after the churn stopped, while only the readers ran.

A heap summary taken at the end of the hold found 4,096 arrays of `DomainConnectionBindingSnapshot` holding 1.79 GB, about 437 KB each, and the same 1.79 GB after the test's workspaces were removed. That matches #225: domain routing kept every ended MCP connection registered, and each of its 4,096 retained routing outcomes copied the full connection list. PR #229 fixed it on `main` on 2026-10-20, and these builds don't include that fix. The footprint figures here and in the reproduction come from builds with the leak, so they aren't evidence about the patch. The retained shard generations and uncached builds above are.

## 6. #222's Done-when criteria and follow-ups

- **Done-when (a), "the patch-versus-rebuild cost is measured for multi-change batches on a large root, and the cap is set from that measurement":** met. Section 2 holds the measurement, and the cap of 4,096 follows the rule there.
- **Done-when (b), in the form "the dominant cost grows with the batch, not the root":** met.
  - Below the cap, the store actor ran no full shard rebuild or full path-index build (gate 2), and the batch-dependent phases take the same time at 10,000 and 100,000 files.
  - Root-sized work remains on the actor. With the materialized path index these runs used, it's the merge copy, 7.28 ms median at 100,000 files, and it's the larger part of the timed-phase total only for add and removal batches below the sizes section 2 gives.
  - The projected path index's patch initializer scans every entry, and its scaling wasn't measured.
- **Done-when (c), "re-running the #213 reproduction shows applying no longer slowing as the root grows":** not met. The applied rate still fell, from 0.96 to 0.29 publications per second. The cause lies outside the patch: work that reads the whole root on each change filled the store actor, and the patch took 2% of its time.

The follow-ups, none filed yet, cover:

- the whole-root reads that run as catalogs change: on the store actor, the token-counting sorted file list, the file panel's root snapshot, the prompt file-tree presentation, and the search catalog merge; on the main thread, the file panel's `FileHierarchyIndex.ownedDescendantPaths` scan on each removal batch;
- the per-file catalog-eligibility checks that the store's ingress drain awaits on the root's `FileSystemService` actor, one file at a time and twice per added file;
- concurrent MCP CLI calls that fail when their connection's routing bind loses the compare-and-swap three times.

Not measured at 550,000 files: the merge copy, the whole apply, subtree-removal scaling, memory, and rebase duty (gates 1(b), 3, 6, and 8). They need a reproduction that drains, which depends on the first follow-up.
