# 13 November: bounded original-image retention candidate

State: source implementation in `repair/original-retention-20261113`, based on the installed-family repair `e90fcc7`. Not installed. No live library, recorded history, capture device, app window or preferences were opened or changed.

## Implemented boundary

- V24 adds an immutable source-position alias and deletion tombstone table. The migration does not scan, rewrite or reindex historical frames. V25–V32 and capture-group schema are excluded.
- New attributed originals use `original_segment_` so an older rollback reader cannot recover or delete them. Legacy V1 and `active_segment_` reads remain supported. Unattributed legacy sessions are retained and reported; recovery continues with other sessions and current recording can start.
- A writer seal does not delete pixels. Cleanup requires same-store durable OCR/deletion proof, current exact archive mapping, verified native decode/timing/dimensions and no original reader. Failed writes, cancellation, restart, changed mappings and corrupt records retain the source.
- New admissions preserve 5 GiB of original-spool capacity and 20 GiB free-space headroom. Pressure refuses the next screen write, seals existing writers and leaves a visible gap notice. It never silently evicts unprocessed originals.
- Archive verification runs in one coalesced App-owned task, joined before SQLite closes. It shares the fresh-OCR governor slot and checks cancellation during native decoding. Recording finalisation does not wait for archive decoding. Durable source receipts provide retry state; no unbounded in-memory archive queue is introduced.
- OCR reads native retained BGRA first, then exact native archive pixels. Saved display/window context comes from the immutable V23 snapshot, since the legacy frame columns do not contain that context.
- `ProcessingConfig.nativeResolutionOCR` is independently off. Its candidate retains native pixels and bounds additional crop and seam requests to 12 and 12 million pixels. `StorageConfig.originalPixelCompression` is independently off; LZFSE/LZ4 records include exact checksums, bounded independent decoding and raw fallback. These are source candidates, not promoted codecs or measured production quality improvements.
- Dashboard reads a cheap cached status. Pressure, resumed capture with missed-update count and legacy recovery verification remain visible; later healthy scans cannot hide a gap.

## Verification receipt

Completed: Swift frontend syntax parse of edited implementation and test files; `git diff --check`.

Compiled debug validation is recorded below. The authored OCR/codec comparison and separate clean optimised build passed; installed acceptance and matched active/idle performance remain open. The root session owns final advisory review. The retention candidate currently has the sole validation slot; all commands use nice 15, two jobs and sanitised noninteractive opt-ins.

Focused suites prepared: `OriginalFrameAliasTests`, `OriginalFrameSpoolTests`, `WALFrameCodecTests`, `WALFrameCompressionTests`, `WALWriterCompressionTests`, `ExactWALFrameTests`, `WALRecoveryTests`, `FrameProcessingSourceReadinessTests`, `VisionOCRIncrementalTests`, `OriginalRetentionStatusTests`. `ScreenTextQualityBenchmarkTests` retains an explicit export opt-in for native authored comparisons.

## Problems prevented during the port

The main workspace's broader candidate pulls V26 capture groups into frame publication and carries an older worker lifecycle. This port omits those dependencies and preserves the installed-family stable single OCR worker. Its metadata codec rejects future fields it cannot preserve instead of discarding their meaning.

The original candidate's extra seam requests were outside its advertised crop budget; they now share the same request/pixel counters. A native-resolution setting change now invalidates cached OCR on an otherwise unchanged frame.

The legacy database frame projection loses display identity. Using it directly for strict original reads would falsely reject valid originals; this port reconstructs the processing reference from the existing immutable capture snapshot while retaining the current archive mapping.

## Remaining gates

One advisory pass is complete and its findings are addressed below. Finish the recorded validation sequence, then make installation a separate recorded decision. Compare representative authored/real acceptance corpora before enabling native crops or compression. Preserve all existing media and rollback material; no historical recompression or deletion is part of this slice.

## Database advisory finding and repair

The app-filter path previously set completed status without an extraction snapshot. Cleanup accepted only OCR provenance, so one intentionally excluded frame could hold a whole original session indefinitely and eventually block recording at the spool ceiling.

V24 now also adds a small `original_frame_extraction_skip` table. The explicit skip transaction validates the captured app, binds the immutable observation and timestamp, completes the queue entry and publishes the receipt together. It does not create text or an OCR revision. `OriginalFrameDisposition.skippedByAppFilter` still requires the current finalised archive and the same Storage verification/reader-drain checks as OCR. Any reset away from completed status deletes the skip receipt; a later status-only completion cannot resurrect it. Changing OCR preferences does not silently rewrite historical decisions. An explicit requeue must acquire new processing proof. Legacy frames without immutable capture attribution keep their old skip behaviour but gain no release authority.

The source-location query uses the existing unique `(storeID,frameID)` alias index; missing, deleted and legacy records return no location. No additional historical scan or alias adoption occurs.

Prepared `OriginalExtractionSkipTests` covers finalisation and no fabricated text, status-only rejection, reset revocation, wrong-app decisions, transaction rollback, legacy handling and deletion. A private in-memory SQLite check parsed all nine V24 migration statements and passed reset/deletion checks; `EXPLAIN QUERY PLAN` confirmed indexed source/frame lookup plus primary-key frame existence. `git diff --check` passed. Compiled Swift tests remain pending the shared build slot; no live database was accessed for this review or fix.

## Advisory fixes before clean validation

- Removed the whole-sweep governor permit. Each original-record proof and each native archive sample acquires and releases separately; reader position survives waits between units, and cancellation leaves durable originals for retry. Fresh transcription gets admission opportunities between archive frames. Native decode stays serial and joined.
- Replaced append-time recursive filesystem accounting with serial file-size/reserve deltas and a shared invalidation epoch for separate recovery owners. Immutable V24 store/frame lookup supplies processing's source path; legacy archive rows do not scan current originals. Maintenance refreshes the small receipt files of each source.
- Coverage is independent of transient verification notices. Counts/reasons/first-last times persist in an atomic, synchronised content-free receipt; pressure, resume, verification failure and restart preserve the gap statement. Dashboard never reads the receipt file.
- App-filter exclusions now publish a durable exact-capture skip disposition rather than pretending blank OCR occurred. It authorises release only with a verified final archive; an explicit processing reset revokes the old skip proof. The actual queue exclusion and later archive-based preparation are covered.
- Inherited the already reviewed noninteractive runner change from `7b0ac80`, which clears both Retrace opt-ins and legacy `RUN_INTERACTIVE` opt-ins. Its Python test passes. No installed setting was changed.

Additional focused checks: `OriginalExtractionSkipTests`, the bounded native-permit/accounting regressions in `OriginalFrameSpoolTests`, durable coverage restart in `OriginalRetentionStatusTests`, and fresh-speech admission between archive units in `BackgroundProcessingGovernorTests`.

## Clean validation attempts

Attempt 1 compiled from a fresh debug scratch directory and stopped because the isolated V23 base lacked the native `FrameConverter.createCapturedFrame` helper. No tests ran. The failed log and original 770-input freeze are retained in `docs/fixtures/repair-20261113-retention/`. The helper was ported narrowly: bounded checked BGRA allocation, direct CGImage rasterisation, preserved capture metadata and cancellation. Tests that migrate to the latest schema now expect V24; deliberately pinned historical/corruption fixtures remain unchanged.

Attempt 2 uses a cleaned debug scratch directory and `source-attempt2.json` (770 inputs; SHA256 `a7fdb97e9441f728ac9e2f6a75ce551debb03250d46bfa586f9cb8c87d7d4e6d`). It compiled successfully and ran 188 tests: 1 skip and 4 failures. The failed runtime receipt remains intact.

Attempt 3 isolated those failures. The legacy fixture had attempted to erase a protected immutable observation; it now inserts a genuinely legacy frame through the lower-level frame SQL path instead. The two recovery fixtures now use `originalFrameForProcessing` to restore immutable display metadata, matching the runtime path. All three passed. No protected-observation guards were removed.

The accounting regression exposed a real 96-byte overcount: Foundation enumerated `/private/var` while owned writes used `/var`, leaving duplicate keys for the same file. Canonical file and reserve keys now share one identity, including removal. The regression still requires exact filesystem-byte equality and additionally checks each cached file and the exact number of unique source files. Attempt 4 recompiles these method-body/test-only changes from the clean-origin debug scratch; no actor or protocol layout changed. Its 770-input freeze SHA256 is `2da00efcdfc1376ca5632e42f72bcc6700cd7b0850114f4b22759c1e2f065a5b`. A separate clean release build remains required.

Attempt 4 focused validation passed: 188 tests, 1 explicit skip, zero failures in 154.5 seconds; command exit 0. The debug build lineage is clean attempt 2 followed by body/test-only fixes, with unchanged actor/protocol layouts. The broader full noninteractive suite is now running against that test binary. Native crop discovery and compression remain off, and the installed app/history are unchanged.

The broader attempt 4 run executed 1,808 tests with 24 explicit skips in 418.0 seconds. It reported three failed assertions in one old finalisation test that assumed raw originals vanished at encoder finalisation. All other tests passed. The failed full-suite receipt is preserved; this is not described as an all-green full-suite run.

Attempt 5 strengthens that single fixture through actual attributed original pixels, injected SQLite finalisation failure, released live-writer ownership, retained-source orphan protection, real recovery, exact pixel reading, durable OCR/verified archive cleanup and eventual orphan repair. All 16 startup/orphan tests passed, no skips/failures, in 52.2 seconds (exit 0). Hash comparison proves this test file is the only input changed since attempt 4; production source remains identical. `source-attempt5.json` SHA256: `1e117462144371f1be37368ade83239feeb040956b0ac7f312b11daaf4463424`. No additional full-suite repeat is required solely for that fixture correction.

The explicitly enabled authored quality comparison uses a fresh `/tmp` JSON path after sanitising inherited environment switches. It renders CoreText images offscreen and uses Vision/native HEVC; it starts no capture or audio device, opens no window and downloads no model.

## Authored quality measurement (not promotion)

The explicit offscreen comparison passed (one test, no skips, 17.7 seconds; exit 0). The fresh exported JSON was copied into the receipt directory as `authored-quality-attempt5.json`. Four sparse authored 4K images contain small text. The scaled baseline recognised no text in any scene (948 total character edits); native crops had two total edits: one missing space before `=` and `const` becoming `constl` in the coloured-code scene. Amounts, identifiers, dates and URL matched. This is useful tiny-text evidence, not complete token fidelity or representative acceptance. macOS document recognition was also ineffective on these fixtures.

Across twelve observations, median OCR wall/process-CPU time was 435.5/226.2 ms for native crops versus 77.4/48.3 ms for the scaled baseline. Native OCR costs more work here and remains disabled. These numbers exclude helper energy, foreground latency and matched active/idle use.

LZFSE restored every original byte and stored 44,543–51,759 bytes per 33,177,600-byte sparse frame; compression took 84.6–151.8 ms and decoding 5.8–10.9 ms. These mostly blank images do not predict real storage savings. Real HEVC files ranged from 16,105 to 40,960 bytes for eight identical observations across tested quality settings; decoded text had zero to two character edits by scene/setting. The tile prototype stored 211,379–226,667 bytes for four observations (base, identical, digit/status change, revert), restored pixels exactly and used no tile payload for the unchanged observation. Different workloads prevent ranking these codecs against each other. Neither representative storage acceptance nor hardware-use/energy acceptance is established. No candidate setting was enabled.

The separate optimised build passed from the fresh `.build-validation/release` scratch directory with nice 15 and two jobs: exit 0 in 604.18 seconds. Final verification matched all 770 frozen inputs; `git diff --check` and the sanitised-runner Python regression passed. Structured outcomes and exact artifact hashes are in `verification-receipt.json` and `artifact-sha256.json` beside the preserved logs. The sole build slot is released. No installation, setting change or source commit was performed by this worker.

## Source checkpoint storage

Complete raw logs remain local. Git retains byte-exact gzip archives; `log-storage.json` maps each log named in the verification receipt to its archive and raw SHA-256. Decompress an archive to inspect the original receipt. This includes failed runs and the later targeted passes. No full-suite green result is implied by the corrected fixture follow-up. Native quality/CPU findings keep promotion disabled.
