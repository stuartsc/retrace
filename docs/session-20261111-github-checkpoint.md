# GitHub source checkpoint — 11 November 2026

Stuart requested: “Add it to the readme, commit everything to github.” The standalone click-through was already committed and pushed as `aa0bed4` on `feature/push-to-dictate`.

## Work recorded

- Added a prominent entry in the root README linking the portable prototype directory, full specification, long issues journal and verification record. Instructions explain that GitHub displays HTML source and that the downloaded folder opens directly in a browser, offline.
- Preserved all existing native source changes in this checkout as a separate source checkpoint: capture/context, original retention, audio/chunk media, exact history/playback, optional recall, resource governor/monitoring, storage reporting, associated tests and authored validation fixtures. This checkpoint is not an installation, release or new acceptance result.
- Kept the source/installed distinction in the README and corrected its obsolete claim that audio capture was disabled.
- Included the previously ignored CPU-repair ledger and June voice-first planning record, plus the intentionally retained native audio diagnostic receipts. Broad Markdown/log ignore rules had hidden those records from ordinary staging.
- Added Python bytecode ignores because the performance-tool tests produced `__pycache__` files. Rebuildable caches, models, installed libraries, credentials and live recording data are not source-checkpoint material.
- Updated the agent guide to locate the prototype and this journal. No linked Jira issue was identified; none was created or assigned speculatively.

## Checks and boundaries

The five new README prototype links resolve to files in the committed portable package. The package's existing 66 app/browser checks, 21 document checks, offline copied-directory checks and manifest are unchanged. The performance scorecard's 39 Python tests pass; the deliberate missing-file test emits its expected diagnostic. The Swift sleep guard passes. Whitespace checks pass.

The complete staged check found three pre-existing trailing spaces in `Storage/Tests/OriginalFrameSpoolTests.swift` that the earlier tracked-only diff did not include. Only those spaces were removed, then the staged whitespace check passed; this makes no behavioural change and is not a new native test result.

The checkpoint includes older native changes rather than newly implemented native functionality in this turn. A clean Swift debug/release build and physical recording/performance acceptance were not rerun for this save-to-GitHub request; retained historical receipts keep their original dates and limitations. The installed app, recording library, macOS settings and network services are unchanged.

Pre-push review checks the changed files and retained archives for provenance, credentials and upload suitability. Only authored audio fixtures and their diagnostic derivatives belong in this checkpoint. The origin repository is public; no real recordings or client secrets are intended for publication. Existing build/test/acceptance limits remain recorded in their delivery ledgers.

The audit covered 442 text inputs, including decompressed diagnostics and archive members. Forty-five scanner matches were SHA-256 metadata. Two existing Rewind SQLCipher key assignments required classification: publication was paused and the finding disclosed without displaying the value. An exact-value comparison then confirmed the same fixed compatibility key in the public upstream `ServiceContainer.rewindSQLCipherPassword` constant, at [upstream revision 266476c](https://github.com/haseab/retrace/blob/266476c24a1db2d92964989fefa27d424eb1d044/App/ServiceContainer.swift#L15). It is retained unchanged as the upstream Rewind import compatibility constant. No account credentials are added or changed. The archive's raw 10- and 15-second controls exactly match the repeated authored speech fixture, and its benchmark source hash matches the supplied test source. The two previously ignored documents and five diagnostic logs also passed the credential scan.

The README entry is committed after the native source checkpoint on the existing feature branch. Publishing the branch does not merge it into `main` or deploy the app.
