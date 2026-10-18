# Build 39 observation issue drafts

> Investigation report, observed 2026-09-12 to 2026-09-13 on production builds 38 and 39 and build 39's release candidates. It records what was true then. Where it disagrees with a current document, the current document is right.

This file drafted four issues from observations on production build 39 and its release candidates. Each was filed with the drafted body, so this file is reduced to a summary:

- #75, "Production relaunch intermittently restores only the current window": after a graceful quit, a relaunch sometimes restored only the window that had been current, not the two others. The draft separated it from #37, which concerns first-run Default workspace persistence.
- #72, "Graceful quit can remain stuck in `terminateLater` while an MCP client is attached": on build 38 the asynchronous shutdown chain never replied, later quit requests and `SIGTERM` couldn't finish it, and two windows closed during the wedge weren't restored. Separate from #11, which concerns signal-triggered termination deferral.
- #73, "`agent_run` steer can cancel a session that's queued to start": a steer sent while the run still showed "Queued to start" ended it as Cancelled. Separate from #12, a steer to an idle session whose wait handle reports expiration.
- #74, "`ContentReadCancellationTests` can fail under parallel tests due to process-wide limiter state": one full-suite run saw 3 active permits instead of 1, while the suite passed 32 tests of 32 when run alone. Separate from #34 and #70, which cover fixture isolation in another suite.
