# Upstream issue 830 Stage 1 Swift TOML dependency proof of concept

> Investigation report, observed 2026-09-03. It records what was true then. Where it disagrees with a current document, the current document is right.

The later decision report, [issue-830-toml-parser-poc-decision-2026-09-05.md](issue-830-toml-parser-poc-decision-2026-09-05.md), came after this one and rejects every Swift TOML dependency, swift-toml 2.0.0 included.

**Scope:** Dependency selection and isolated Swift Package Manager proof only. This work didn't integrate RepoPrompt CE product code or use a live Codex app server.

## Recommendation

**Provisional GO for maintainer consideration:** use [`mattt/swift-toml`](https://github.com/mattt/swift-toml) with an exact `2.0.0` requirement:

```swift
.package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0")
```

Use `.product(name: "TOML", package: "swift-toml")`. On the proof host, Swift Package Manager resolved the tag to commit `827506c90475e82d5a7f191f950fb3025cbdc0d6`. Retain the exact manifest requirement together with that `Package.resolved` revision, and review any revision change before it can alter accepted user configuration.

**NO-GO for product integration until maintainer acceptance:** on the single proof host, version 2.0.0 passed the syntax, type, adapter fail-close, debug/release build, upstream-test, and package-footprint checks below. Primary-source review found MIT license terms and current maintenance signals, but it doesn't settle legal or security acceptance. The public API also doesn't preserve source order or expose per-entry source locations, while the current upstream issue 830 plan assumes both capabilities.

## Candidate evaluation

| Candidate | Evaluated release | Result | Evidence and rationale |
| --- | --- | --- | --- |
| [`mattt/swift-toml`](https://github.com/mattt/swift-toml) | [`2.0.0`](https://github.com/mattt/swift-toml/releases/tag/2.0.0) | **Recommend for maintainer decision** | TOML 1.0 parser, Swift 6 package, configurable decoding limits, line/column syntax errors, MIT license, and no transitive Swift Package Manager dependencies. Version 2.0.0 replaced direct Swift/C++ interoperability with a C bridge. |
| [`dduan/TOMLDecoder`](https://github.com/dduan/TOMLDecoder) | [`0.4.5`](https://github.com/dduan/TOMLDecoder/releases/tag/0.4.5) | Reject | Actively maintained and pure-Swift in its production target, but the current parser accepts TOML 1.1.0. Pinning the older TOML 1.0 release would omit later stability fixes, so it isn't a safe match for the plan's strict TOML 1.0 boundary. |
| [`LebJe/TOMLKit`](https://github.com/LebJe/TOMLKit) | [`0.6.0`](https://github.com/LebJe/TOMLKit/releases/tag/0.6.0) | Reject | Provides a convenient runtime table API and uses the same toml++ 3.4.0 core, but its [package manifest](https://github.com/LebJe/TOMLKit/blob/0.6.0/Package.swift) uses Swift tools 5.4 and adds `Checkit` plus `swift-docc-plugin` to the resolved graph. It offers no compensating compatibility or supply chain advantage over the selected package. |

## Swift Package Manager and compilation proof

The isolated package used `// swift-tools-version: 6.2` on macOS 26.6.2 (build 25G83) with Xcode 26.6 (build 17F113) and Apple Swift 6.3.3 targeting arm64 macOS 26.0. The work didn't change a repository manifest or source file.

```text
Package.resolved version: 3
identity: swift-toml
location: https://github.com/mattt/swift-toml.git
version: 2.0.0
revision: 827506c90475e82d5a7f191f950fb3025cbdc0d6
Package.resolved SHA-256: d17064bb097d42d5c1bc28c0d6e22bf202e004e4ebaedb25efe3a10b248de53a
```

Because this is a source-control dependency, its `Package.resolved` pin has no registry checksum field. The auditable package identity is the exact version and revision above; the file SHA-256 records the local resolution artifact.

Executed proof commands:

- `swift package --package-path <scratch package> resolve` produced the exact resolution above.
- `swift package --package-path <scratch package> show-dependencies --format json` reported `swift-toml` with an empty dependency list.
- `swift build --package-path <scratch package>` succeeded in debug configuration.
- `swift build --package-path <scratch package> -c release` succeeded.
- `swift test --package-path <scratch package>/.build/checkouts/swift-toml` passed all 146 upstream tests across 7 suites.
- `swift run --package-path <scratch package>` exercised the 21-assertion compatibility matrix. Six independent invocations supplied the order probe below.

The clean dependency source is about 852 KB. Its bundled toml++ 3.4.0 single header is 17,888 lines. The Secure Hash Algorithm 256 value is `01d450ea609bcd47f78b75eb7e5fbbf3a1e78ef79955ef283c9301af5a7933a2`.

## Focused compatibility and safety results

The scratch executable decoded the full document through `TOMLDecoder`. It extracted only `mcp_servers` and applied explicit limits: 4 MiB input, depth 64, 10,000 keys per table, 100,000 array elements, and 1 MiB strings. Representative fields match the official [Codex configuration reference](https://developers.openai.com/codex/config-reference) and [Codex MCP configuration guide](https://developers.openai.com/codex/mcp). Eligibility and source fail-close rows below describe policy implemented by the POC adapter around the parser; they're not built-in library behavior.

| Behavior | Result |
| --- | --- |
| Stdio and streamable-HTTP definitions | Pass |
| Strings, integers, doubles, Boolean values, arrays, inline tables, and nested tables keep distinct types | Pass |
| A quoted date-looking value remains a string | Pass |
| TOML date/time and non-finite floats become unsupported definitions under adapter policy | Pass |
| Non-Boolean `enabled` becomes an ineligible definition under adapter policy | Pass |
| Missing, unreadable, malformed, duplicate-key, and oversized sources fail closed under reader/adapter policy | Pass |
| TOML 1.1-only `\e` escape is rejected | Pass |
| Malformed input reports line 3, column 10 without emitting the embedded secret sentinel | Pass |
| Server table source order | **Fail: not stable across processes** |

Twenty-one deterministic assertions passed on every run. In a six-process order probe, the two server names appeared in source order twice and reversed four times. The decoder code explains the result: [`TOMLKeyedDecodingContainer.allKeys`](https://github.com/mattt/swift-toml/blob/2.0.0/Sources/TOML/Decoder.swift#L492-L501) enumerates a Swift dictionary. Source order isn't an API contract and can't drive display order or revision generation.

## Plan mismatches and required adaptation

1. **Ordered entries:** the plan says entries appear in their first safe source position. The selected library doesn't expose source order. Use an explicit canonical key sort for deterministic snapshots and UI ordering, or revise the rule before integration.
2. **Per-entry locations:** the plan defines `sourceLocations: [CodexTOMLSourceLocation]`. Version 2.0.0 exposes line and column only for [`invalidSyntax`](https://github.com/mattt/swift-toml/blob/2.0.0/Sources/TOML/Decoder.swift#L362-L389); semantic values and table entries have no source spans. Report syntax locations, but keep semantic statuses location-free unless maintainers separately approve a source-indexing design.
3. **Privacy boundary:** parser error messages aren't safe UI or telemetry payloads because they may reflect user input. The adapter should keep only validated line/column integers and map failures to owned status codes.

A second TOML lexer or parser would violate the plan's dependency-first boundary. Canonical sorting and syntax-only locations are the smallest adaptation candidates for the maintainer to accept or reject before integration.

## Primary-source due diligence

- The selected [2.0.0 manifest](https://github.com/mattt/swift-toml/blob/2.0.0/Package.swift) declares Swift tools 6.0, C++17 for the internal C bridge, and no package dependencies.
- The selected package and bundled parser are MIT licensed: [`swift-toml` license](https://github.com/mattt/swift-toml/blob/2.0.0/LICENSE.md), [toml++ 3.4.0 release](https://github.com/marzer/tomlplusplus/releases/tag/v3.4.0), and [toml++ license](https://github.com/marzer/tomlplusplus/blob/v3.4.0/LICENSE).
- The upstream [continuous integration workflow](https://github.com/mattt/swift-toml/blob/2.0.0/.github/workflows/ci.yml) covers Swift 6.0 to 6.2 on macOS and Linux. A [weekly workflow](https://github.com/mattt/swift-toml/blob/2.0.0/.github/workflows/check.yml) checks for toml++ updates.
- As reviewed on 2026-09-03, GitHub lists no published advisories for [`swift-toml`](https://github.com/mattt/swift-toml/security/advisories) or [toml++](https://github.com/marzer/tomlplusplus/security/advisories), and neither repository publishes a security policy. This is a monitoring caveat, not proof of absence of vulnerabilities.
- The upstream integration test invokes `toml-test@latest`. That affects upstream test reproducibility, not the consumer dependency graph; RepoPrompt CE should rely on pinned local fixtures for compatibility regression coverage.

**Maintainer question:** Do you accept `https://github.com/mattt/swift-toml.git` pinned exactly at `2.0.0` for upstream issue 830, with canonical server ordering and line/column diagnostics limited to syntax errors?
