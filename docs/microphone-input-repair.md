# Microphone input recovery and repair

## Live diagnosis — 6 October 2026

The installed app remained **2610.1.1** (`f1551be`), with the V23 library.
The user's report of absent audio needed a signal check, not another file-count
check. Eight sampled AAC files around 22:46–22:49 decoded successfully, but each
contained only zero-valued PCM samples. Their presence did not establish that
sound had been captured.

The native app log identifies **MacBook Pro Microphone** as the input opened at
21:44:41.838 AEST. macOS Sound settings later showed **Studio Display Microphone**
as the selected input. The live hardware state reported the laptop lid closed.
Apple documents a hardware microphone disconnect on Apple-silicon laptops when
the lid is closed: <https://support.apple.com/en-au/guide/security/secbbd20b00b/web>.
The installed source chooses the default microphone at startup and has no owner
for default-input or microphone connection changes.

This explains the demonstrated live silent input; it is separate from the older
transcription queue/display defects. One selected file from each of 1–6 October
decoded to nonzero audio. That is not proof of continuous or intelligible speech
throughout those dates. No-record rows between 18:56:31 and 21:57:21 on 6 October
also intersect macOS sleep/dark-wake logs, followed by full wake at 21:57:20.
Do not infer that every blank historical panel is either harmless or data loss.

## Immediate runtime recovery

The existing app was paused normally for five minutes and immediately resumed.
No system input preference, permission, codec, audio file or transcript row was
edited. The final pre-pause audio ended at **22:49:51.620**, and the first resumed
audio began at **22:50:00.261**: an **8.641-second** recording gap.

The resumed session logged **Studio Display Microphone** at 22:50:00.146. Fresh
AAC files decoded to nonzero audio. One initial converter rejection was logged
before normal delivery; it is not hidden as uninterrupted coverage.

The user then spoke a new test sentence. Three bounded 15-second inputs were
decoded locally and checked with the existing local Whisper small model, GPU
disabled and two CPU threads. Two overlapping recordings contained the expected
words `test`, `after` and `restart`; `microphone` was not matched. This verifies
captured speech and partial recognition of that test, not complete phrase
accuracy, app transcript publication or general Whisper quality. The diagnostic
printed only fixed expected-word matches and counts. Its temporary PCM copies
were removed after checking; original recordings remain unchanged.

## Narrow source repair

Work is isolated in `/Users/stuartbond/backintime-hotfix-microphone-routing`,
based on combined display/queue source `50778412480d6ba98651a1904edb617fb59418bf`.
The signed **2610.6.1** display/queue candidate and its clean source remain intact.

The accepted design follows the exact macOS default input UID, observing default
input and device connection changes. Notifications are coalesced under one
owned routing task. Switching retains the same public audio stream, joins old
sample callbacks, drains/resets conversion state and replaces only the selected
microphone input. Missing/unavailable input remains eligible for a later device
event. Stop revokes the active generation and joins routing/callback teardown,
so late notifications cannot restart capture after pause. It does not select an
arbitrary substitute microphone, alter permissions or restart screen capture.

## Source validation

The initial RED run reproduced absent routing with four cases and sixteen
expected failures. Review then identified a stop/restart ownership race and
unnecessary reopening of a healthy microphone on unrelated device events.
Three additional RED cases reproduced those faults with six expected failures;
the final owner retires stop ownership before completion and scopes reconnect
intent to the selected input UID.

A clean debug rebuild passed **38 XCTest tests, zero failures/skips**: twenty
routing, ten native conversion, two bounded-stream and six capture-lifecycle
cases. Compilation took 456.24 seconds and the suite 1.529 seconds. Native
CoreAudio observer registration/removal was real, while input enumeration and
session attachment were controlled so tests did not open microphones or change
the user's selected device. PCM sample buffers and conversion were native.

The clean build exposed an implicit raw-pointer warning in CoreAudio UID
retrieval. The local SDK explicitly assigns ownership of the returned CFObject
to the caller. An explicit `Unmanaged<CFString>` pointer and retained-value
transfer correct that local method body without changing actor/protocol
layouts. The same **38 tests** then passed again, with zero failures/skips and
the introduced warning gone (10.72-second incremental build, 1.498-second suite).
Existing duplicate-rpath warnings remain unrelated. Both receipts are retained;
the trailing Swift Testing zero-test report is not the XCTest count.

The final profile reports 94.12% of routing-owner regions, 100% of the coalesced
event source and 87.10% of delegate regions exercised. Native hardware wrapper
coverage is lower because physical device selection/attachment was deliberately
not performed. These figures do not establish native hardware acceptance or
branch coverage.

The separate empty-scratch optimized product build passed at **23:45:58 AEST**
(356.90 seconds reported by Swift; 358.55 seconds including orchestration).
All **379 product inputs** were unchanged before/after compilation. The retained
unbundled executable SHA-256 is
`0597cd164617ba46d00e70739251038d9b599804b0d4d593c1c225bf54edfb89`.
Independent review approved the final source, including the native ownership
correction, with no outstanding findings.

Physical input switching, sleep/wake and installed automatic recovery remain
separate checks. The installed source and its bounded startup verification are
recorded below; source tests alone do not establish those hardware behaviors.

## Installation status

The user successfully packaged **2610.6.1** in their normal signing-capable
Terminal. Its 39 compiled payload sections match the reviewed unbundled binary.
This Codex command environment still fails native signature verification; no
signature check is bypassed.

The native installer later stopped at `writer_present` before creating a backup,
installation-attempt receipt or staged app. Retrace itself had quit correctly.
An independent SSH-origin `sqlite3_rsync` process held the live database and WAL
open read/write. That copy was left intact, and the existing app was relaunched
to avoid leaving recording stopped while it completed. Its audio pipeline
resumed at 23:05:01.802; the gap from the last saved audio was **232.927 seconds**.

The subsequent native install succeeded. Build **2610.6.1**, source `5077841`,
reopened at 23:19:43 on the Studio Display microphone, with V23 and checked
persisted settings preserved. That install's recording gap was **210.012
seconds**. Newly captured pending audio now appears and starts playback in
both Live and Timeline. A brief explicit processing check completed a fresh
quiet AAC as probable silence and returned to automatic mode after cancellation.
See the [freshness ledger](audio-transcription-freshness-repair.md) for details.

The automatic-routing source was prepared for native delivery as **2610.6.2**.
The command session reports zero signing identities and rejects strict
verification of the native installed app; the user's normal Terminal is the
proven signing/delivery path. No signature check is bypassed.

The reviewed `deliver.py` helper packages while recording continues, checks the
pinned executable and post-packaging Mach-O payload, then waits for the user to
quit normally before invoking the guarded installer. It retains a unique
payload receipt and the existing app/database rollback checks.

## Installed local trial — 7 October 2026

The user completed normal-Terminal packaging and installation. The payload
receipt verifies all **39 compiled sections**; native installation completed
at **07:33:57.638 AEST**. The installed build is **2610.6.2**, source
`0dbdbe366c788ae270909bccdc06b54bd142e2c4`, with executable SHA-256
`77a0d96bb6c432af95dd2a0dc960fa6fd322038997558b15255766b3ef594713`.
The installer retained the previous 2610.6.1 app and verified database rollback
copy, and reported no library writes. The original V23 schema and checked
recording/context/exclusion preferences match the installation receipt.

The new process (PID 18866 at verification) logged default-input connection at
**07:34:34.854**, then a running session following the default input at
**07:34:35.359**. One startup format-conversion rejection preceded normal
delivery; the earlier retained screen-WAL recovery failure also remains
separate from audio. New raw AAC batches advance every ten seconds. Two newly
saved clips at 07:35:35 and 07:35:45 decode successfully to 240,576 samples each
with nonzero input. This verifies capture data and decoder operation, not
spoken-word accuracy or continuous coverage.

The final saved pre-quit audio ends at **07:33:00.821** and the first new audio
begins at **07:34:35.389**: a **94.568-second recording gap**. The original
recordings remain in place.

An exact-name `pgrep` initially missed the still-running old process; the agent
corrected that false closed-app report after checking its full executable path.
The computer-use service then disconnected during the normal Quit attempt and
failed to reconnect. The user performed Quit/install/reopen. No forced process
termination or alternative UI automation was used. Full-path process checks,
native receipts and actual AAC decoding establish the bounded results above.

Physical input switching and sleep/wake have not yet been exercised on the
installed build. Computer use remains unavailable, so the fresh Live/Timeline
UI check from 2610.6.1 is not promoted to a rendered-UI check of 2610.6.2.
The latest audio is still pending text preparation. Overnight 2610.6.1 text
outputs visible at 07:18 were generic speech descriptions, which demonstrate
worker progress but do not establish useful transcription accuracy.

`post-install-audio-20261007.json` and `installation-complete.json` retain the
scoped checks. This documentation update does not change the installed product
source commit or its preserved compiled artifacts.

Content-free receipts, source review of the scoped local speech diagnostic and
its fixed-word results are retained under
`~/Library/Application Support/Retrace Candidates/2026-10-06-microphone-routing/`.
