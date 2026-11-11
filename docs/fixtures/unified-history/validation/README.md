# Unified history validation receipts

These are completed local source/build/test checkpoints, not installed acceptance.
Each command receipt records its exact arguments, source manifest, exit status and
whether those source inputs changed during execution. Original complete logs and
native helper diagnostics remain under `/tmp/retrace-unified-20260924/`.

- `clean-integrated-tests-3-v30`: clean compilation/link succeeded. Nineteen V30
  exact transcript tests and the audio batching/backlog/lifecycle/refinement
  groups passed. The suite stopped on a repeated XCTest teardown callback, after
  three legacy-schema fixtures failed. Both issues were subsequently repaired.
- `v30-runtime-focused-1`: 171 selected tests, 10 assertion failures in eight
  cases. Capture groups, masks, archive identity, admission, semantic persistence
  and workspace selection passed. Native AX acquisition and an invalid shared
  memory fixture remained failing.
- `clean-integrated-tests-4-cross-source`: clean build stopped on the new job
  reference case in meeting-evidence validation. The compatibility repair rejects
  job references in that context; it does not add meeting evidence.
- `cross-source-runtime-1`: compilation/link succeeded; all 71 selected non-AX
  tests passed, including the repaired V28 fixtures, separate audio reader,
  exact audio/job resolution and mixed-source bookmarks. Fourteen native AX cases
  ran, with 10 assertion failures across eight cases. The retained categorical
  trace exposed native line-range errors and early identity/observer failures.
  The later endpoint/readiness repair still requires native execution.

The subsequent job-owner and combined search/UI slices have independent source
review and authored regression tests. Their integrated runtime gate is pending.
No live history, installed application, preference, candidate promotion or
release is established by these receipts. Optional model/speech/codec/native UI
comparisons and physical display/sleep/wake/performance acceptance remain separate.
