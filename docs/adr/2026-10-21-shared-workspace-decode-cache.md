# Windows share decoded workspace documents through a content-keyed cache

Status: accepted, 2026-10-21
Sources: #226, `docs/ledgers/2026-10-21-issue-226-port-1158-shared-decode-cache.md`

## Context

Each window keeps its own decoded copy of every workspace in the catalog, compose and stashed tabs included, and each window decodes changed documents itself. #226 measured 273 MiB of decoded tab arrays on a debug app with four windows and 48 workspaces, about 68 MiB per window.

The first fix kept only the shown workspace decoded in each window and moved every read or write of another workspace's tabs behind an asynchronous gateway. It reached 63 files and about 11,000 changed lines before its hardest part, the workspace switch, was started, and each review round found new ordering bugs between a window's copy, the runtime's accepted revision, and other windows. It was stopped on 2026-10-21. The branch `bugfix/226-per-window-tab-loading` and the ledger on it are kept as the record.

Upstream kept the synchronous per-window model and, in upstream PR 1158, made byte-identical documents decode once per process.

## Decision

- Every window keeps its synchronous, full-catalog workspace list. No feature changes how it reads or writes tabs.
- `WorkspaceFileDecodeCache.decodeWorkspace(documentBytes:)` caches decoded models by the SHA-256 of the document bytes, process-wide, ported from upstream PR 1158 (`6efc7d93`): at most 128 entries and 64 MiB of input, least recently used evicted first, and a larger document never cached. Windows that decode the same bytes share the decoded storage; a window that edits its copy gets its own storage for what it changed.
- A decode that invents a value for a missing field (an ID, a date, or the default tab normalization creates) is never cached, so two documents with identical incomplete bytes keep separate identities.

## Alternatives considered

- Decode only the shown workspace in each window (#226's first design): retains less than the cache. On the measured catalog with four windows, the saving is at most about 40 MiB: the cache's 56.9 MiB less at least 16.8 MiB of tab state for the four shown workspaces. The estimate before measuring was 50 to 100 MiB. In exchange, every access to another workspace's tabs becomes asynchronous, the workspace switch has to be rewritten, and this repository's workspace model diverges from upstream in the files upstream changes most. Stopped after review kept finding ordering bugs.
- Share a decoded copy only between windows showing the same workspace: leaves every window decoding the rest of the catalog.
- No change: four windows keep four catalog copies.

## Consequences

- Retained decoded tab storage is about one catalog copy plus the stale entries the cache still holds, whatever the window count. On the debug app with the production archive's catalog (36 workspaces, 40 MiB of documents), it was 94.6 MiB with one window and 213.0 MiB with four before, and 59.5 MiB and 56.9 MiB after.
- One window still keeps a full catalog copy and saves only the duplicate the legacy file-load cache used to keep. #226's goal, a window that keeps only its shown workspace decoded, isn't met.
- The limits bound input bytes, not decoded memory. A catalog with more than 128 workspace documents or more than 64 MiB of them gets no sharing when a window opens, because every window decodes the catalog in the same order.
- Every decode hashes its input. The domain runtime already computes a content digest that a later change could reuse.
- Ports of upstream changes that read or write tabs stay translations of synchronous code.
- Revisit when normal use is many windows and the remaining tab storage is the binding cost, when the catalog approaches the limits, or after #233 removes the encoded-document copies.
