# Responsiveness repair handoff — 13 November 2026

The user authorised implementing the repair plan. Fast draft text target is 2–5 seconds, followed by refinement. Routine testing must not take over the screen. No computer use, app restart, installation, live library mutation, history deletion or model download has occurred in this session.

## Ready primary repair

Workspace `/Users/stuartbond/backintime-responsiveness-20261113`, branch `repair/responsiveness-20261113`.

- Frozen recovery baseline `25296e1`; repair `e90fcc7` pushed; validation/runner hardening `7b0ac80` committed, push pending.
- Source recovery matched 753/763 installed inputs. Nine changes and one removal are the previously authorised Live lazy-scroll restoration. Original audio/governor/Timeline sources match installed build2610.22.5. Recovery checkout was preserved.
- Fixed recent/old first-pass fairness, paced single-thread overdue work, native cancellation when fresh speech arrives, coalesced durable-text notifications, cached bounded audio queue reporting, and Timeline current-head refresh that preserves intentional history browsing.
- Default-off native microphone draft preview; CPU Whisper remains canonical. HEVC reporting distinguishes availability/requested selection from unverified actual hardware use. Existing periodic storage reporting remains.
- Noninteractive runner removes inherited interactive switches, sets private diagnostic logging, uses nice15/jobs2 and a20GiB disk floor. No UI automation.
- Clean debug:1,320.27s. Focused187tests/1skip/0failures. Full1,719tests/23skips/0failures in392.979s. All688 frozen code inputs matched.
- Separate clean optimised build passed450.98s. Receipts and compressed logs in `docs/fixtures/repair-20261113`.
- Native speech authored test skipped: Apple assets absent. User approval to download is pending; do not download without reply. No2–5s, CPU/energy or physical acceptance claim.

Signed build2611.13.1 is prepared at:
`/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-11-13-responsiveness/Retrace 2611.13.1 candidate.app`

Binary matched the optimised-build receipt before RPATH/signing changes. Developer ID deep strict verification passed; installed executable/plist hashes unchanged. Packaging review findings were fixed. The new app-only installer `install_app_only.py --check` passed without mutation. `--install` has never run; installer advisory review is in progress. Retains only the old app, uses current library, no database copy or migration. Arrange a normal-quit restart after the concrete installer is verified. Do not use `build_and_sign.sh`, which kills/replaces the installed app automatically.

Primary packaging scripts/receipts/journal remain uncommitted until installer review. Running app is still2610.22.5. Signing team CC88WZ5SQ7. No credentials logged.

## Phased native text

Workspace `/Users/stuartbond/backintime-streaming-20261113`, branch `repair/phased-transcription-20261113`, basee90fcc7. Agent `phased_native_text` owns files and currently the sole Swift build slot.

Default-off covered native first-pass reuse binds source generation/continuity/sample ranges and encoded AAC SHA to ordered SpeechAnalyzer results-finalisation acknowledgements. Durable save callback does not wait for inference. Covered text becomes searchable needs_repair; one later CPU comparison retains native candidate provenance. Incomplete/late/system audio falls back to CPU. Microphone only. Preview latency differs from durable latency: governor delay beyond60s coverage retention falls back safely; no guarantee under prolonged pressure.

Initial clean compile hit an exclusivity error; fixed with a stateless static helper. Failed log `/tmp/retrace-phased-native-clean.log` retained; retry `/tmp/retrace-phased-native-retry1.log`, session11436, now linking/compiling final tests. Source frozen. Worker must report result, commit checkpoint, then root arranges one advisory review. No native asset opt-in/download.

## Original retention / OCR

Workspace `/Users/stuartbond/backintime-retention-20261113`, branch `repair/original-retention-20261113`, basee90fcc7. Agent `original_retention` owns source; uncommitted and not compiled yet.

Bounded V24-only additive original-pixel alias/skip proofs. No V26+ migration or history rewrite. Raw originals retained until durable extraction or explicit policy skip, verified exact archive and drained readers. Legacy unattributed WAL remains visible/retained without blocking startup. Native OCR crops and LZFSE/LZ4 remain default off until gates.5GiB spool/20GiB headroom.

One non-DB advisory review found: entire archive sweep held one freshOCR permit; every append rescanned all spool metadata; verification errors hid capture-gap notices. Worker is fixing resumable permit units, serial byte/source indexes, independent durable gap coverage.

DB advisory review confirmed excluded-app frames pinned originals forever. `retention_database_review` implemented minimal DB/Shared skip proof +6 regressions: exact source binding, atomic completion, final archive requirement, proof revocation on reset, no fake OCR. Indexed originalFrameLocation added. Private SQLite migration/reset/deletion and EXPLAIN checks passed; Swift tests pending. Worker integrates Processing call and Storage lookup. No more duplicate reviews; run clean tests after changes freeze and build slot is free.

## AAC storage

Original candidate `/Users/stuartbond/backintime-storage-20261113`, branch `repair/storage-20261113`, commit `ef3eeb2` pushed. Default-off compactor removes only validated zero padding; packets/priming/timing preserved. Advisory high issue around staging failure was fixed with full original-or-candidate readback fallback.

Independent smoke:60,047→37,086bytes (38.238% savings), all171,707 Apple-decoded PCM samples identical; independent FFmpeg before/after identical. This is one authored file, not promotion or historical cleanup.

V23 port `/Users/stuartbond/backintime-aac-20261113`, branch `repair/aac-v23-20261113`, base7b0ac80. Root owns. Only compactor, AudioSegmentWriter option, native tests and retained fixture ported. `.aac-validation` contains exact copied production Shared +two audio files +real XCTest/fixtures for a clean component test without rebuilding unrelated UI. Prepared but not run; wait for native build slot. Tests require >=20% savings at3durations, exact packets/PCM/seeks/timing and filesystem failure handling. Option remains default off. Final integrated clean app build still required before rollout.

## Next actions

1. Finish installer review, address concrete findings, commit/push primary candidate records. Arrange restart separately; retain installed state until answered.
2. Finish native focused tests and one advisory review. Native model download approval remains pending.
3. Run isolated AAC native tests in next build slot; do not overlap CPU-heavy Swift builds.
4. Freeze repaired retention source, run clean focused/full tests and separate clean release before promotion. Integrate validated slices deliberately, not by replacing V23 with the large main V24–V32 candidate.
5. Retain source, test, signing, installation and physical acceptance as separate states. Full plan still includes two-source native streaming, unchanged-frame occurrence navigation, unique chunk storage and representative quality/energy gates.

Disk available45GiB last check; preserve20GiB. Main workspace has a pre-existing user modification to AGENTS.md; do not stage/revert it. Commit only this owned handoff. Main handoff previous commit is local and push pending.

Memory used: MEMORY.md1260–1263 and1278–1281. Final reply must include memory citation block; rollouts01a15dce-680d-71f1-aaac-9f03713f0a29 and01a08fec-d782-7cd3-9801-2de32d112239. No memory updates authorised.
