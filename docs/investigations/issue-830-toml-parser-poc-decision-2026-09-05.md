# Upstream issue 830 TOML parser proof-of-concept decision

> Investigation report, observed 2026-09-05 on TOMLDecoder 0.4.5, swift-toml 2.0.0, and TOMLKit 0.6.0 against bundled Codex 0.149.0 and Codex 0.152.0. It records what was true then. Where it disagrees with a current document, the current document is right.

This decision came after the Stage 1 proof of concept, [issue-830-codex-user-mcp-bridge-poc-2026-09-03.md](issue-830-codex-user-mcp-bridge-poc-2026-09-03.md), and reverses its provisional recommendation of swift-toml 2.0.0.

The parser comparison package is archived on the fork at `ForkArtifacts/issue-830/docs/investigations/issue-830-toml11-parser-poc/` on the `feature/830-design-archive` branch: https://github.com/mplibunao/repoprompt-ce/tree/feature/830-design-archive/ForkArtifacts/issue-830/docs/investigations/issue-830-toml11-parser-poc

Each "Raw evidence" path below is relative to that package's folder.

## Decision

**NO-GO. Add no Swift TOML dependency to RepoPrompt CE.**

The verdict is derived, not asserted. `results/summary.json` evaluates an explicit gate policy of
24 gates against the raw lane outputs and reports NO-GO when any blocking gate fails. 16 gates
pass and 8 fail: `dialect-parity`, `order-projection`, `mutation-transaction`, `no-crash`,
`no-sanitizer-finding`, `structured-line`, `adversarial-classification`, and
`debug-latency-budget`. Verification recomputes each of those gate values directly from the raw
JSON and regenerates the whole summary into a temporary location to compare it field by field, so
a stored gate result is never accepted as its own evidence.

Those 8 failures reduce to four independent defects in `dduan/TOMLDecoder` 0.4.5:

1. **Dialect.** It disagrees with both pinned Codex binaries on 2 of 48 differential documents. It
   accepts an integer above the signed 64-bit range that both runtimes reject, and it rejects a
   UTF-8 byte-order-mark document that both runtimes accept. The byte-order-mark rejection is also
   the sole cause of the `order-projection` and `mutation-transaction` failures, so those two gates
   are consequences of this defect rather than separate ones.
2. **Resource safety.** It stack-overflows and crashes on a deeply nested dotted-key document of
   1,048,574 bytes, which is below the 1 MiB preflight cap, in both debug and release.
   AddressSanitizer attributes the crash to unbounded recursion in the parser itself, so no
   post-parse limit can prevent it.
3. **Diagnostics.** It exposes no structured syntax position. A line number is present only inside
   free-form error text, which production code must not parse.
4. **Debug latency budget.** Three wide-table documents exceed the 5-second debug budget. They
   complete correctly when re-measured, so this is a slow configuration rather than a hang, and it
   is the weakest of the four findings.

`adversarial-classification` fails at 69/74 because it counts exactly those same 2 crashes and 3
debug budget misses, so it restates defects 2 and 4 rather than adding a fifth.

`mattt/swift-toml` 2.0.0 and `TOMLKit` 0.6.0 are reproducible negative controls. Each matched 42
of 48 documents, failing the same six TOML 1.1 escape cases, because both embed toml++ in TOML 1.0
mode.

Because no pure-Swift candidate passed, the stop condition applies: a separately scoped decision
between owning a native parser and running an out-of-process helper on the Codex TOML grammar
family. No preprocessing, dual-parser design, permissive retry, or scanner expansion is
recommended.

## Measurement environment

| Property | Value |
|---|---|
| Toolchain | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101) |
| Xcode | 26.6 (17F113) |
| Host | macOS 26.6.2, arm64 |
| Package deployment target | macOS 14.0 |
| Acceptance oracle | bundled Codex 0.149.0, `sha256 f4a74117b8142cda581c95ff753abf4508b5636d89682c1ed77e4a9249af8963` |
| Regression oracle | Codex 0.152.0, `sha256 166e0593c333c1c6412cc9cea72b6e1dfc4fc79b4813da02c511a3339c9b9593` |
| Oracle signing | `Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)` for both binaries |
| Oracle command | `CODEX_HOME=<fresh-temporary-home> codex mcp list --json` |

The dialect runner verifies each oracle's version string, content hash, and signing identity
against pinned expectations, and requires both valid and malformed controls to behave correctly,
before any fixture executes. Any mismatch aborts the run rather than producing a verdict against an
unverified binary. Each invocation used a fresh temporary `CODEX_HOME` holding one synthetic
`config.toml`, and every temporary home is confirmed removed after use. The command loads
configuration and does not start configured MCP servers, so no fixture caused a network operation
or touched real user state.

## Gate matrix

| Gate | TOMLDecoder 0.4.5 | swift-toml 2.0.0 | TOMLKit 0.6.0 |
|---|---|---|---|
| Exact tag resolved and built, debug and release | PASS | PASS | PASS |
| Codex 0.149.0 accept/reject parity | **FAIL, 46/48** | **FAIL, 42/48** | **FAIL, 42/48** |
| Codex 0.149.0 and 0.152.0 agree | PASS, 48/48 | PASS, 48/48 | PASS, 48/48 |
| Server name sets on accepted documents | PASS, 13/13 | not evaluated after elimination | not evaluated after elimination |
| Declared keys and values on every MCP-bearing document | PASS, 13/13 | not evaluated after elimination | not evaluated after elimination |
| Declared oracle-reported fields | PASS, 13/13 | not evaluated after elimination | not evaluated after elimination |
| Exhaustive declarations including env and headers | PASS, 6/6 | not evaluated after elimination | not evaluated after elimination |
| Ordered MCP projection across all legal forms | **FAIL, 26/28** | not evaluated after elimination | not evaluated after elimination |
| Deterministic order across 100 repeats | PASS, 28/28 | not evaluated after elimination | not evaluated after elimination |
| Mutation transaction, including existing owned sections | **FAIL, 26/28** | not evaluated after elimination | not evaluated after elimination |
| No crash or sanitizer finding on adversarial corpus | **FAIL, stack overflow** | not evaluated after elimination | not evaluated after elimination |
| Structured syntax line number | **FAIL, 0/48** | not evaluated after elimination | not evaluated after elimination |
| Deterministic diagnostics across 100 repeats | PASS, 48/48 | not evaluated after elimination | not evaluated after elimination |
| Adversarial fixtures classify as expected | **FAIL, 69/74** | not evaluated after elimination | not evaluated after elimination |
| Release latency gates | PASS, 4/4 | not evaluated after elimination | not evaluated after elimination |
| Debug latency budget | **FAIL, 3 over budget** | not evaluated after elimination | not evaluated after elimination |
| Peak memory gate for a 1 MiB document | PASS | not evaluated after elimination | not evaluated after elimination |
| No native code in the production target | PASS | FAIL, bundled C++ | FAIL, bundled C++ |
| Overall | **FAIL** | **FAIL** | **FAIL** |

Per the accepted gate policy, the two toml++ wrappers stopped at the dialect lane once eliminated,
so their unevaluated cells reflect scope rather than an unknown result.

# 1. Measured local results

## Lane 1: differential grammar corpus

48 documents ran against five engines. The corpus allocation matches the accepted design: 12
strings and escapes, 8 duplicates and redefinition, 8 dotted/inline/table construction, 6
whole-document malformed, 6 numeric and date/time, 4 Unicode and encoding, and 4 representative MCP
configurations.

| Result | Value |
|---|---|
| Codex 0.149.0 and 0.152.0 identical accept/reject | 48/48 |
| Corpus expectations confirmed by Codex | 48/48 |
| TOMLDecoder 0.4.5 parity with Codex 0.149.0 | 46/48 |
| swift-toml 2.0.0 parity | 42/48 |
| TOMLKit 0.6.0 parity | 42/48 |

The two candidate mismatches are:

| Fixture | Codex 0.149.0 and 0.152.0 | TOMLDecoder 0.4.5 |
|---|---|---|
| `n04-integer-overflow` | reject | **accept** |
| `u01-bom` | accept | **reject** |

Both directions are unsafe for the bridge. Accepting an over-range integer means RepoPrompt would
treat a document as valid that the runtime refuses to load; rejecting a byte-order-mark document
means RepoPrompt would refuse a configuration the user's Codex accepts today. The accepted gate
eliminates a candidate on a single mismatch.

Both negative controls failed the same six documents: `s02-escape-e`, `s03-escape-x41`,
`s04-escape-x1b`, `s05-mixed-escapes`, `s06-escape-in-quoted-key`, and `p04-quoted-escaped-names`.
Every one is a TOML 1.1 escape form that Codex accepts.

### Semantic agreement, and what each metric actually covers

The oracle is not a peer of a TOML parser, so semantic agreement is split into two metrics with
stated scope rather than one metric that quietly covers less than its name suggests.

| Metric | Scope | Result |
|---|---|---|
| Server name sets | names on every accepted MCP-bearing document | 13/13 |
| Declared keys and values | every key each fixture declares, and its expected value | 13/13 |
| Declared oracle-reported fields | `arguments`, `command`, `enabled`, `url` | 13/13 |
| Exhaustive declarations | `name`, `command`, `url`, `enabled`, `arguments`, `env`, `httpHeaders` | 6/6 |

The fixture manifest is the authority. All 13 MCP-bearing documents declare, independently of any
parser, which keys each server carries and what each supported field should hold. The candidate's
own report of which keys it saw is a value under test compared against those declarations, never
the yardstick that decides what gets compared. A declared key the candidate omits, a value that
differs, a key list that disagrees, and a supported field reported but never declared all count as
failures.

`codex mcp list --json` reports only name, command, url, enabled, and args, and it fills schema
defaults the source never states, so oracle comparison covers the declared keys that map onto
those four fields. `env` and `http_headers` never appear in oracle output at all, so the six
exhaustive declarations are the only check that can see them.

Six adversarial checks confirm the metrics have teeth: omitting a declared `command`, giving it a
wrong value, omitting a declared `env`, misreporting the key list, and reporting an undeclared
field each drop declared key/value agreement to 12/13, and corrupting an `http_headers` value
additionally drops exhaustive agreement to 5/6.

`codex mcp list --json` also emits servers sorted by name: all 6 multi-server documents came back
alphabetized regardless of declaration order. The oracle therefore confirms which servers and
values a document yields, but never declaration order, which Lane 2 asserts against each fixture's
declared order instead.

Raw evidence: `results/dialect.json`, `Fixtures/dialect/`.

## Lane 2: ordered projection and mutation transaction

14 integration fixtures ran in debug and release, each repeated 100 times, for 2,800 total order
projections. The exercised transaction is `validate source → index layout → raw owned-field
mutation → validate output → second-application byte identity`.

| Result | Value |
|---|---|
| Fixture configurations | 28 |
| Total projections | 2,800 |
| Configurations producing exactly one distinct order and projection hash | 28/28 |
| Expected order recovered | 26/28 |
| Mutation transaction passed | 26/28 |

Ordered extraction succeeded for non-lexicographic regular headers, quoted names containing dots
and spaces, TOML 1.1 escapes in names and values, dotted assignments, inline root tables, nested
subsections, implicit parents, interleaved unrelated tables and comments, multiline basic and
literal header decoys, and missing or empty `mcp_servers`. No nested subsection was emitted as a
second server, and every projection was byte-stable across 100 repeats in both configurations.

A mutation counts as passing only when it proves preservation. For every repeat the harness
requires that the output reparses, that the line-level difference from the source is confined to
the owned `[features.code_mode]` header or its `enabled` assignment, that the unrelated semantic
projection is byte-identical before and after, that every comment survives unchanged, that the
newline style is unchanged, and that a second application is byte-identical. Negative checks
confirm the confinement predicate rejects an edited unrelated value, a dropped comment, and a
reordered server list.

Two fixtures exercise mutation of an existing owned section, which the append-only fixtures never
reach: replacing an existing Boolean, and inserting the owned key into a section that lacks it.
Both carry comments and CRLF line endings. All 4 configurations satisfied every preservation
assertion above.

The two failures are `o11-bom-crlf` in debug and release. Both are the byte-order-mark rejection
already recorded as `u01-bom`, not a separate ordering or mutation defect: the parser rejects the
document, so no order is produced and no mutation runs.

All three no-write controls behaved correctly and wrote nothing: an invalid escape in an unrelated
field failed source validation, an over-cap document failed source validation, and an owned-value
conflict was detected before mutation. This confirms that complete recursive materialization
rejects a document whose only defect sits in a field the bridge never reads.

Raw evidence: `results/order-mutation.json`, `Fixtures/order/`.

## Lane 3: diagnostics, adversarial limits, and performance

### Diagnostics

The 24 documents TOMLDecoder rejects as syntax errors ran 100 times each in debug and release, for
48 cases.

Stability alone would not be evidence, since a diagnostic that never decoded would also be
"stable". Every repeat must exit zero, decode a record, and classify as a syntax error before the
determinism result counts; all 48 cases meet that precondition.

| Result | Value |
|---|---|
| Cases whose every repeat decoded and classified as expected | 48/48 |
| Cases with identical category, message, line, and column across 100 repeats | 48/48 |
| Cases exposing a structured line number | 0/48 |
| Cases exposing a structured column | 0/48 |
| Cases where a line number appears only inside free-form error text | 32/48 |

Diagnostics are perfectly reproducible, which satisfies the determinism requirement. The
structured-position requirement fails outright. `TOMLError` surfaces only a description; two thirds
of the rejections embed a position in prose such as `(Line 2) Ill-formed key.`, and the remaining
third carry no position at all. Recovering a location would require parsing that text, which the
accepted design prohibits.

### Adversarial and structural limits

The adversarial corpus is regenerated from scratch on every run and verified against a manifest of
37 fixtures with exact sizes and digests before measurement, so a stale fixture cannot enter the
resource evidence. Those fixtures ran in debug and release as isolated child processes: 69/74 cases
passed.

**Crash, both configurations.** `depth-max-under-byte-cap.toml`, 1,048,574 bytes, terminated on
SIGSEGV in debug and release, reproducibly. Under AddressSanitizer the same fixture aborts with:

| Property | Value |
|---|---|
| Sanitizer error class | `stack-overflow` |
| Dominant frame | `Parser.parseKeyValue(bytes:tableIndex:isKeyed:)` |
| Dominant frame repeats | 253 of 255 reported frames |

The document is below the 1 MiB preflight cap, which is the only limit that runs before the parser.
The proposed depth limit of 128 cannot help, because the process dies inside the parser before any
traversal happens.

Each sanitizer record comes from a single subprocess invocation whose exit status, decoded output,
and standard error are captured together, so a status can never be attributed to a different run
than the report it came from. Coverage means every fixture produced either a clean decoded run or
a recognized sanitizer report; a timeout or a nonzero exit the sanitizer did not explain counts as
a failure rather than as coverage. <!-- generated:sanitizer -->
The sweep recorded 36 clean and 1 sanitizer finding across 37/37 fixtures, with 0 timeouts and 0 unclassified failures.
<!-- /generated:sanitizer -->


<!-- generated:debug-budget -->
**Debug latency budget, 3 cases.** `nodes-49999`, `nodes-50000`, `nodes-50001` exceeded the 5-second debug budget. Re-measured once at a generous budget, all 3 completed correctly at 8.01 s, 7.86 s, 9.05 s and produced the expected classification, so this is a slow debug configuration rather than a hang. The same fixtures complete in 0.65 s to 0.68 s in release, well inside the 2-second release budget.
<!-- /generated:debug-budget -->


Every other boundary behaved as specified: inputs at limit − 1, limit, and limit + 1 for bytes,
depth, node count, array length, string length, and server count classified correctly; invalid
UTF-8 at the beginning, middle, and end was rejected before parsing; and near-cap malformed
documents were rejected as syntax errors.

### Release performance

Five warmups followed by 30 measured release child-process invocations per fixture. Timing includes
process startup and is therefore conservative. A latency figure counts only when every sampled run
exited zero and produced the expected decoded classification, so these numbers cannot be timings
of a failure.

<!-- generated:performance -->
| Fixture | Bytes | p50 | p95 | Max | Gate | Result |
|---|---:|---:|---:|---:|---:|---|
| `representative-64k.toml` | 65,536 | 3.75 ms | 4.16 ms | 4.29 ms | p95 ≤ 25 ms | PASS |
| `near-1mib-valid.toml` | 1,048,576 | 5.18 ms | 6.33 ms | 6.46 ms | p95 ≤ 500 ms | PASS |
| `near-1mib-invalid-eof.toml` | 1,048,573 | 5.50 ms | 5.83 ms | 5.86 ms | p95 ≤ 500 ms | PASS |
| `bytes-limit-plus-1.toml` | 1,048,577 | 3.84 ms | 4.25 ms | 4.27 ms | p95 ≤ 10 ms | PASS |
<!-- /generated:performance -->

<!-- generated:memory -->
Peak resident memory for a 1 MiB document exceeded an independent small-fixture baseline by 2,228,224 bytes against the 64 MiB gate. This is a rough differential estimate between two separate processes rather than an in-process allocation measurement, and it bounds the true figure in neither direction.
<!-- /generated:memory -->

Performance is comfortably inside every release gate and does not rescue a candidate that failed
dialect, resource safety, and diagnostics.

Raw evidence: `results/characterization.json`, `Fixtures/adversarial/`.

## Lane 4: Swift package and supply chain

Measured for TOMLDecoder 0.4.5, revision `a2bbd2796fe3064e107de18cb56031052c4fa899`.

<!-- generated:package -->
| Property | Value |
|---|---|
| Clean debug build | pass, 6.49 s |
| Incremental debug build | pass, 0.38 s |
| Clean release build | pass, 6.98 s |
| Incremental release build | pass, 0.37 s |
| Upstream package tests | pass, 751 tests in 8 suites |
| Native source files in the production target | 0 |
| Unsafe flags in the manifest | none |
| Optional dependencies present in the resolved graph | none |
| Checkout size excluding version control | 32,927,783 B |
| Release probe executable | 739,136 B |
| Stripped release probe executable | 468,768 B |
| Release object files | 3,576,720 B across 30 files |
<!-- /generated:package -->

The manifest gates optional dependencies on four environment variables: `TOMLDECODER_BENCHMARKS`,
`TOMLDECODER_DOCS`, `SPI_GENERATE_DOCS`, and `TOMLDECODER_FORMATTING`. With none of them set, the
resolved graph contains only the three evaluated candidates, and neither `benchmark`,
`swift-docc-plugin`, nor `SwiftFormat` appears. The single plugin declaration belongs to the
benchmark target and is inert unless `TOMLDECODER_BENCHMARKS=1`. Rather than assume those switches
were absent, every resolve, build, and test in this lane runs with all four explicitly removed from
the environment, and the run records that none were inherited and none were present.

<!-- generated:sizes -->
Cross-candidate release probe sizes were 739,136 B for TOMLDecoder, 811,440 B for swift-toml, and 1,066,752 B for TOMLKit. These are isolated probe executables, not RepoPrompt application deltas.
<!-- /generated:sizes -->


Raw evidence: `results/package-audit.json`, `results/dependency-audit.json`, `Package.resolved`.

# 2. Primary-source facts

- TOMLDecoder 0.4.5 is MIT licensed (`LICENSE.md`), uses Swift tools 6.0, declares C++20 at package
  level, and ships a Swift-only production target with no runtime package dependency.
- swift-toml 2.0.0 carries MIT grant text without an SPDX title line and vendors toml++ through 3
  native files under a C++ bridge. TOMLKit 0.6.0 is MIT licensed and vendors toml++ through 8
  native files.
- Both wrappers embed toml++ configured for TOML 1.0. Enabling toml++ unreleased-language features
  would require carrying a package modification and selecting a bundle of draft behavior rather
  than the exact Codex dialect, so it is not an acceptable repair.
- `TOMLError` is public, but its `reason` enum is internal. Escape errors expose free-form
  descriptions only.
- TOMLDecoder's table representation groups values, arrays, and child tables rather than preserving
  arbitrary global source order. Because every valid MCP server is a child table, insertion order
  survives within that category, which Lane 2 confirms empirically for every legal construction
  form tested.
- Only TOMLDecoder performs a full recursive materialization of the document. swift-toml exposes no
  public parsed tree and the probe can only prove that its decoder accepted the document;
  TOMLKit's probe proves only that the root table was constructed. Their records report
  `root_decode_only` and `root_table_only` rather than claiming a full traversal.
- `codex mcp list --json` loads configuration without starting configured MCP servers, which is
  what makes it a low-side-effect runtime oracle.

# 3. Architectural inference

These statements are reasoning, not measurements, and none of them may substitute for the results
above.

- TOMLDecoder has the smallest production and supply-chain footprint of the three candidates, and a
  pure-Swift parser avoids a C++ exception surface and a vendored upstream the wrapper must track.
- The stack-overflow class of defect is intrinsic to a recursive-descent parser without an internal
  depth guard. A fix requires either an upstream depth limit or an external bound applied before
  parsing, and a byte cap alone is not such a bound because nesting depth is not proportional to
  document size.
- Ordering behavior that Lane 2 confirms for 0.4.5 rests on an implementation property rather than
  a documented API guarantee, so it would need re-proving on every version bump.
- Parser throughput is not the operative risk for configuration files of ordinary size. Bounded
  failure latency and bounded memory matter more, and those are exactly where the candidate fails.
- An out-of-process helper on the Codex grammar family could provide hard process-level resource
  boundaries and designed ordered output, at the cost of packaging, signing, multi-architecture,
  and lifecycle work.

# 4. Unresolved gaps

- **Host operating system.** The accepted matrix names macOS 14. These results come from macOS
  26.6.2 on arm64 with a macOS 14.0 deployment target. Behavior was not re-measured on a macOS 14
  host.
- **Swift version.** The accepted matrix names Swift 6.2; the available toolchain is Swift 6.3.3.
- **Application size and build-time delta.** Not measured. Integrating a dependency into the root
  package is outside this proof of concept's authorization, so only isolated probe sizes and POC
  build times exist.
- **RepoPrompt mutation replay.** The validated mutation transaction was exercised inside the proof
  of concept, not against `CodexIntegrationConfiguration`. Product integration is blocked pending
  approval, so no product test was added or run.
- **Peak memory attribution.** The 1 MiB figure subtracts two independent processes and is an
  upper-bound estimate rather than an in-process allocation delta.
- **Machine load.** Measurements ran on a shared workstation rather than a quiet machine. Release
  latency results clear their gates by roughly two orders of magnitude, so the margin absorbs this,
  but the absolute numbers are not a benchmark.
- **Negative-control depth.** swift-toml and TOMLKit were eliminated at the dialect lane, so their
  probes never implement a full-document traversal and their resource, ordering, and diagnostic
  behavior remains unmeasured.

# 5. Corrected acceptance requirements

After these results, the issue 830 bridge requirements state that acceptance is strict
whole-document parity with bundled Codex 0.149.0 with 0.152.0 as the regression oracle, that parse
success means parse plus complete recursive materialization, that the formatting-preserving mutator
is a layout mechanism rather than the validity authority, and that the dependency decision is NO-GO
with the native-versus-out-of-process decision opened as the stop condition. The accepted write
order is unchanged:

`validate source → project ordered semantics → formatting-preserving raw mutation → validate output → atomic write`

## Maintainer-guidance check

- **User impact and invariant:** Importing a user's Codex configuration must accept exactly what
  the pinned runtime accepts, preserve declaration order, and never present an unreadable document
  as an empty server list.
- **Root-cause confidence:** Confirmed. Each disqualification is a reproduced behavior with a named
  fixture, not an inference from documentation.
- **Authority:** The two pinned Codex binaries are the acceptance oracle, and the runner refuses to
  proceed unless their identity and controls verify. Exact tagged candidate source defines
  candidate capability.
- **State-safety risks:** A dialect mismatch in either direction corrupts the accept/reject boundary
  for real user configuration. A parser-stage crash on user-supplied input is a denial-of-service
  surface, since `config.toml` is user-controlled.
- **Scale and observability risks:** Release latency and memory are bounded and well inside gates.
  Diagnostics are reproducible but not machine-readable, so a user-facing error could not reliably
  point at a line.
- **Recommended scope:** Stop at NO-GO. Open the separately scoped native versus out-of-process
  decision before any further parser work on this issue.
- **Validation boundary:** Four proof-of-concept lanes ran to completion under the full-evidence
  reproduction mode. Product mutation replay remains out of scope until a dependency is approved.
