# Responsiveness repair handoff — 13 November 2026

The user authorised implementing the repair plan. Fast draft text target is 2–5 seconds, followed by refinement. Routine testing must not take over the screen. No computer use, app restart, installation, live library mutation, history deletion or model download has occurred in this session.

## Ready primary repair

Workspace `/Users/stuartbond/backintime-responsiveness-20261113`, branch `repair/responsiveness-20261113`.

- Frozen recovery baseline `25296e1`; repair `e90fcc7` pushed; validation/runner hardening `7b0ac80`; signed installer/receipts at `8193ebb`, cleanup receipt at `6e4c123`. Primary branch pushed through8193ebb; latest cleanup push in flight at this checkpoint.
- Source recovery matched 753/763 installed inputs. Nine changes and one removal are the previously authorised Live lazy-scroll restoration. Original audio/governor/Timeline sources match installed build2610.22.5. Recovery checkout was preserved.
- Fixed recent/old first-pass fairness, paced single-thread overdue work, native cancellation when fresh speech arrives, coalesced durable-text notifications, cached bounded audio queue reporting, and Timeline current-head refresh that preserves intentional history browsing.
- Default-off native microphone draft preview; CPU Whisper remains canonical. HEVC reporting distinguishes availability/requested selection from unverified actual hardware use. Existing periodic storage reporting remains.
- Noninteractive runner removes inherited interactive switches, sets private diagnostic logging, uses nice15/jobs2 and a20GiB disk floor. No UI automation.
- Clean debug:1,320.27s. Focused187tests/1skip/0failures. Full1,719tests/23skips/0failures in392.979s. All688 frozen code inputs matched.
- Separate clean optimised build passed450.98s. Receipts and compressed logs in `docs/fixtures/repair-20261113`.
- Native speech authored test skipped: Apple assets absent. User approval to download is pending; do not download without reply. No2–5s, CPU/energy or physical acceptance claim.

Signed build2611.13.1 is prepared at:
`/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-11-13-responsiveness/Retrace 2611.13.1 candidate.app`

Binary matched the optimised-build receipt before RPATH/signing changes. Developer ID deep strict verification passed; installed executable/plist hashes unchanged. Packaging review findings were fixed. The new app-only installer `install_app_only.py --check` passed without mutation. `--install` has never run; installer advisory review completed; both medium findings fixed and3 private-filesystem failure/check tests passed. Retains only the old app, uses current library, no database copy or migration. Arrange a normal-quit restart after the concrete installer is verified. Do not use `build_and_sign.sh`, which kills/replaces the installed app automatically.

Primary packaging scripts/receipts/journal and verbatim reviewed quiescence helper are committed. Initial thin push failed with missing necessary objects; --no-thin retry succeeded. Running app is still2610.22.5. Signing team CC88WZ5SQ7. No credentials logged.

## Phased native text

Workspace `/Users/stuartbond/backintime-streaming-20261113`, branch `repair/phased-transcription-20261113`, basee90fcc7. Source checkpoint complete; no active build in this workspace.

Default-off covered native first-pass reuse binds source generation/continuity/sample ranges and encoded AAC SHA to ordered SpeechAnalyzer results-finalisation acknowledgements. Durable save callback does not wait for inference. Covered text becomes searchable needs_repair; one later CPU comparison retains native candidate provenance. Incomplete/late/system audio falls back to CPU. Microphone only. Preview latency differs from durable latency: governor delay beyond60s coverage retention falls back safely; no guarantee under prolonged pressure.

Initial clean compile hit an exclusivity error; fixed with a stateless static helper. Failed receipt retained. Focused78tests/2skips/0failures; full1,733tests/24skips/0failures in568.024s. Single advisory review passed. Checkpoint0ea09c9; receipts/runner correction at957ceb7, pushed. No Swift inputs changed during full validation. Separate clean release will be validated in the integrated audio-delivery candidate below; no model download/native acceptance.

## Original retention / OCR

Workspace `/Users/stuartbond/backintime-retention-20261113`, branch `repair/original-retention-20261113`, basee90fcc7. Agent `original_retention` owns source and the sole Swift build slot. Source is uncommitted, frozen for clean validation.

Bounded V24-only additive original-pixel alias/skip proofs. No V26+ migration or history rewrite. Raw originals retained until durable extraction or explicit policy skip, verified exact archive and drained readers. Legacy unattributed WAL remains visible/retained without blocking startup. Native OCR crops and LZFSE/LZ4 remain default off until gates.5GiB spool/20GiB headroom.

One non-DB advisory review found: entire archive sweep held one freshOCR permit; every append rescanned all spool metadata; verification errors hid capture-gap notices. These fixes and regressions are implemented: per-record proof/native archive permits; serial byte accounting; indexed canonical source lookup; independent durable gap coverage. Swift validation is in progress.

DB advisory review confirmed excluded-app frames pinned originals forever. `retention_database_review` implemented minimal DB/Shared skip proof +6 regressions: exact source binding, atomic completion, final archive requirement, proof revocation on reset, no fake OCR. Indexed originalFrameLocation added. Private SQLite migration/reset/deletion and EXPLAIN checks passed; Swift tests pending. Processing call and Storage lookup are integrated. No duplicate review loop. Attempt1 failed compilation because the V23 base lacked the archive CGImage-to-BGRA helper; narrow helper added. Attempt2 is fully clean with770 inputs, manifest SHA256 a7fdb97e9441f728ac9e2f6a75ce551debb03250d46bfa586f9cb8c87d7d4e6d. Active session28392; log docs/fixtures/repair-20261113-retention/clean-focused-attempt2.log, freeze source-attempt2.json. Storage/DB/Processing compiled; App/UI compilation underway. Worker will run focused, full, authored offscreen OCR/codec export and separate clean release sequentially. No other Swift build may overlap.

## AAC storage

Original candidate `/Users/stuartbond/backintime-storage-20261113`, branch `repair/storage-20261113`, commit `ef3eeb2` pushed. Default-off compactor removes only validated zero padding; packets/priming/timing preserved. Advisory high issue around staging failure was fixed with full original-or-candidate readback fallback.

Independent smoke:60,047→37,086bytes (38.238% savings), all171,707 Apple-decoded PCM samples identical; independent FFmpeg before/after identical. This is one authored file, not promotion or historical cleanup.

V23 port `/Users/stuartbond/backintime-aac-20261113`, branch `repair/aac-v23-20261113`, base7b0ac80. Root owns. Only compactor, AudioSegmentWriter option, native tests and retained fixture ported. `.aac-validation` contains exact copied production Shared +two audio files +real XCTest/fixtures for a clean component test without rebuilding unrelated UI. Clean native component tests passed5tests/0skips/0failures; source copies matched.10s/15s/21.248s clips saved39.719%/30.578%/23.902%; exact packets, cookie, priming/remainder, PCM and seeks preserved. Unknown/malformed/symlink/denied-write checks passed. Commit08ebb78 pushed. Option remains off in this standalone branch. Generated .aac-validation/.build was removed after completed validation, with source/receipts retained.

## Integrated audio delivery — queued validation

Workspace `/Users/stuartbond/backintime-audio-delivery-20261113`, branch `repair/audio-delivery-20261113`, commit92dd2dc, clean and not yet pushed. Agent `phased_native_text` implemented fromdf0176c +AAC cherry-pick7d3466a +reviewed runner fix.

Immutable App AudioWriterPolicy captures production compaction ON unless `audioContainerPaddingCompactionDisabled` is true; private-test initialiser OFF. All five writer factories use it. Native gates stay OFF. Compaction finishes before SQL size and native digest proof. Existing files untouched. Real AAC policy/rollback and compacted-file native proof tests added. One bounded integration review passed with no findings. Python runner test passed; Swift tests NOT RUN. Queue clean focused integration plus separate clean release after retention releases the build slot. Do not rerun the whole component reviews.

## Pending user answers and next actions

Two asynchronous questions are still unanswered:
1. Approval to download missing Apple English speech assets for authored tests while preserving20GiB. No download without answer.
2. Timing approval to normal-quit/install signed2611.13.1/reopen in background. No install/restart without answer. Installation is staged because it creates a recording gap; no forced termination or foreground testing.

Finish retention validation; address actual failures and retain receipts. Then validate integrated audio-delivery with clean focused Swift tests and clean optimised build, package only after passing. Native full suite already passed against unchanged0ea09c9 inputs; AAC component native tests passed. No native2–5s, CPU/energy, installed or representative quality acceptance claim.

Root removed only completed owned primary debug scratch and AAC component build after no-open-handle check; free-space delta1,790,832,640bytes, with concurrent-work caveat. Signed candidate, release binary, source and receipts retained. Live recording library untouched. Free space was~45GiB before cleanup; preserve20GiB throughout.

Main workspace has a pre-existing user modification to AGENTS.md; do not stage/revert it. This handoff's prior commit3488ed1 was pushed. Connected Jira search found no matching Retrace/backintime issue; no unrelated issue changed. Native and AAC branches pushed; primary latest cleanup push result needs polling (session17665).

Full plan still includes two-source native streaming, unchanged-frame occurrence navigation, unique-chunk storage and representative quality/energy gates. Main already holds larger V24–V32 candidates and global performance tooling (`docs/performance-measurement.md`, `scripts/performance_benchmark`); do not reimplement or install that broad tree as a shortcut. Narrow current work remains separate.

Memory used: MEMORY.md1260–1263 and1278–1281. Final reply must include memory citation block; rollouts01a15dce-680d-71f1-aaac-9f03713f0a29 and01a08fec-d782-7cd3-9801-2de32d112239. No memory updates authorised.
