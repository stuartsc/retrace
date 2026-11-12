# Retrace repair handoff — 13 November 2026

## Goal and current state

Restore prompt, useful transcription and a Timeline that opens at the newest saved
moment. The user selected fast draft text in 2–5 seconds followed by refinement.
Improve CPU/load control, native processing and storage without weakening recorded
history. Routine testing must not take over the screen.

**Signed candidate 2611.13.2 is ready, not installed. Installed app remains
2610.22.5.** No CUA, visible testing, app restart, installation, model download,
recording-library mutation or settings change occurred in this session. Two user
questions remain unanswered: normal restart timing and permission to download
missing Apple speech assets. Do not treat elapsed time as either answer.

## Ready delivery

Workspace `/Users/stuartbond/backintime-audio-delivery-20261113`, branch
`repair/audio-delivery-20261113`. Production integration `92dd2dc`, release input
checkpoint `b495d4a`, validation `d68b4bc`, packaging recipe `8ff1b7b`, signed
candidate record `284c20a`. The branch is pushed; confirm the remote tip after any
new commits. No Swift build remains active; the sole build owner has released it.

The delivery includes:

- First-pass audio stays eligible as it ages: three recent turns and one oldest
  turn, with paced one-thread overdue work during activity. Fresh speech cancels
  and joins waiting/running overdue native work; recordings remain pending.
- One expensive automatic job, cached bounded queue summaries and quiet scheduler
  grant reuse. Fresh speech may bypass only the app CPU soft cap, retaining host,
  thermal and memory pressure gates. No measured 20% CPU claim.
- Coalesced durable-text commit updates in Live, with the fallback poll retained.
- Normal Timeline opening and Now refresh the newest saved head while deliberate
  historical browsing/search handoffs remain pinned. Ordinary opening no longer
  starts screenshot/OCR capture.
- New AAC files remove only validated zero container padding. Existing media,
  packets, codec settings, priming and sample timing stay unchanged. All five App
  writer factories use one restart-scoped policy; rollback preference is
  `audioContainerPaddingCompactionDisabled`. Library defaults remain off.
- Two native microphone options are implemented but default off:
  `liveMicrophoneDraftTrialEnabled` and `nativeFirstPassReuseTrialEnabled`.
  Finalised native coverage is bound to source continuity, exact sample ranges and
  final encoded-file identity. Missing/incomplete/late/system proof falls back to
  CPU. Native covered text is searchable pending later CPU comparison. Preview
  latency differs from durable latency; coverage expires safely after 60 seconds.
- HEVC availability/requested preference/verified use are reported distinctly.
  Existing periodic storage reporting is retained. Global power settings unchanged.

Candidate folder:
`/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-11-13-audio-delivery`

`install_app_only.py --check` passed and created no candidate files or receipts.
`--install` has NOT run. It requires normal Quit and no recording writer, verifies
old/new identities and signatures, retains only the old app and swaps only the app.
No database copy, schema transition or media-format transition; rollback uses the
current V23 library. Do not launch a candidate alongside the installed app. Do not
use `build_and_sign.sh`, which kills/replaces the live app automatically.

## Verification

- Combined clean actual-product integration: **15 tests, zero skips/failures**;
  compilation 314.73s, tests 3.453s. All 348 production inputs, seven exact fixture/
  test copies and dependency pins matched. Actual App/Processing/Storage/Shared/
  Database products, no replacement production modules or UI test target.
- Combined clean whole-app optimised build: **passed, 3,736.19s**. All 751 code,
  resource, native and build inputs matched before/after. Raw executable SHA256
  `2f606db9d0cca8f5de6ff3302581d62f050c434948a22a290a07b7093dd13e38`.
- Earlier release attempt was deliberately interrupted because its inventory was
  too narrow. Its receipt remains; the final run used the complete freeze. Owned
  process groups were joined/drained. Three interruption ownership tests passed.
- Slow release initially suffered severe host scheduling pressure (observed load
  average 603.57); final app compilation was CPU-bound. No priority increase or
  unowned process intervention. The compiler exited before a requested short
  sample; no optimiser hotspot was established.
- Packaging independently matched all 751 inputs and tied focused inputs to their
  tested Git commit. Six native audio libraries copied from actual build inputs
  and individually signed. Retained Sparkle 2.8.1 unsigned arm64 code matches the
  actual build artifact. Developer ID deep strict verification passed.
- Two medium advisory packaging findings were fixed: bind focused evidence to
  release inputs, and publish readiness only after installer materials finish.
  Inherited old bundle revision/manifest metadata was also corrected. Four private
  installer tests pass, including stale metadata rejection and post-swap failure.
- Actual installer preflight passed; candidate files and installed executable/
  plist hashes unchanged. Native runtime acceptance and live CPU/latency remain open.

Receipts and compressed logs:
`/Users/stuartbond/backintime-audio-delivery-20261113/docs/fixtures/repair-20261113-audio-integration-harness`

Delivery journal:
`/Users/stuartbond/backintime-audio-delivery-20261113/docs/audio-delivery-integration-20261113.md`

## Separate checkpoints retained

- Primary responsiveness: `/Users/stuartbond/backintime-responsiveness-20261113`,
  pushed `6e4c123`. Clean debug 1,719 tests/23 skips/zero failures; clean release
  passed. Earlier signed 2611.13.1 remains preserved, superseded for proposed
  installation by 2611.13.2. Installed source recovery matched 753/763 inputs; the
  nine UI changes and one removal are the authorised Live lazy-scroll restoration.
  Original recovery checkout and history preserved.
- Native first pass: `/Users/stuartbond/backintime-streaming-20261113`, pushed
  `957ceb7`. Clean-origin focused 78 tests/two skips/zero failures; full 1,733/24/
  zero failures on unchanged Swift source `0ea09c9`. A compile exclusivity error
  was corrected with a stateless helper; failed receipt retained. Native assets
  absent; no download, actual inference or 2–5-second acceptance. Its clean
  optimised validation is the combined build above, not an invented separate run.
- AAC: original `/Users/stuartbond/backintime-storage-20261113` at `ef3eeb2`;
  V23 port `/Users/stuartbond/backintime-aac-20261113` at `08ebb78`, both pushed.
  Five real native tests passed. Authored 10/15/21.248-second clips saved
  39.719%/30.578%/23.902%, with identical packets/cookie/priming/remainder/PCM/seeks.
  Unknown formats and failed writes preserve validated original output. No
  representative whole-library savings claim. Combined Storage guide already
  documents the compactor and tests; no further guide edit is needed.
- Original retention: `/Users/stuartbond/backintime-retention-20261113`, pushed
  `04c491e`. V24-only original/skip proof, unit-sized admission, cached canonical
  spool accounting, indexed lookup and independent durable gap receipts. Native
  OCR/compression stay off; 5 GiB spool/20 GiB headroom; no V26+ migration.
  Focused 188 tests/one skip/zero failures. Full 1,808 tests/24 skips had three
  assertions in ONE obsolete fixture; the strengthened startup/recovery follow-up
  passed all 16 tests with production unchanged. Do not call that full run green.
  Clean optimised release passed 604.18s, all 770 inputs unchanged. Receipt:
  `docs/fixtures/repair-20261113-retention/verification-receipt.json` in that tree.
  Offscreen authored quality passed; four sparse 4K tiny-text scenes showed two
  character edits and ~4.7x process CPU for native OCR. Lossless pixel restoration
  passed but sparse-frame compression is not representative acceptance. No promotion.

## Remaining work and boundaries

1. Await the user's normal restart timing. After authorised installation, reopen
   in the background and verify recording/text advancement and installed identity
   without foreground control. Preserve/measure the recording gap.
2. Await speech-asset download approval, preserve 20 GiB free, then run authored
   native en-AU accuracy/coverage/latency checks. Both native flags remain off until
   evidence supports a scoped trial; physical microphone acceptance is separate.
3. Matched active/idle CPU, whole-system/helper energy/memory, foreground p95 and
   representative quality/storage acceptance remain open. Existing framework is
   `docs/performance-measurement.md` and `scripts/performance_benchmark/` in main.
4. Two-source native streaming, exact unchanged-frame occurrences, unique audio
   chunks and broader native/OCR hardware evaluation remain gated work. The larger
   main V24–V32 tree already holds candidates; do not install it as a shortcut or
   bulk-recompress historical media.

Owned completed primary-debug/AAC component caches were removed after an open-
handle guard; actual free-space delta was 1,790,832,640 bytes, with concurrent-work
caveat. Source, release binaries, signed candidates and receipts retained. No live
recordings deleted. Free space stayed above 20 GiB throughout (~42 GiB after builds).

Main `/Users/stuartbond/backintime` retains the user's pre-existing AGENTS.md edit;
do not stage or revert it. Main README/changelog describe separate repair branches,
not incorporation into main or installed acceptance. Connected Jira search found no
matching Retrace/backintime issue; no unrelated issue or external message changed.

Memory used: MEMORY.md1260–1263 and1278–1281; final reply needs one memory citation
block. Rollouts 01a15dce-680d-71f1-aaac-9f03713f0a29 and
01a08fec-d782-7cd3-9801-2de32d112239. No memory update authorised or performed.
