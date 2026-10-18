# Issue draft — admission suite instability against a fresh profile

> Investigation report, observed 2026-09-12. It records what was true then. Where it disagrees with a current document, the current document is right.

This file drafted the issue filed as #70, "`ConcurrentSameWorkspaceAgentRunAdmissionTests` fails or hangs against a fresh profile root". The issue carries the drafted body, so this file is reduced to a summary.

The draft's finding: against a newly created profile root the suite failed or hung (7 runs: 4 clean, 2 failures, 1 hang), and against one reused profile root it passed 8 runs of 8. That isolated first-run Default workspace creation as the trigger. The failures fell on the `testCanonicalAdmissionRefresh*` family with "workspace binding was not durably accepted".

Its triage notes, kept out of the issue body, named issue #37 as the probable root cause: the Default workspace record is persisted by an untracked task that activation doesn't await. They also recorded that the suite and the workspace manager path still existed on upstream `main` at `4b2b914d`.
