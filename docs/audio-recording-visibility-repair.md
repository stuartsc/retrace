# Saved audio visibility repair — 3 October 2026

## Observed problem

The installed 2610.1.1 app continues saving microphone AAC batches, while the
timeline's Audio Transcript panel reports no recordings. The panel's initial
and refresh reads both use `getTranscriptions` with its default
`includeActivityRows: false`, which excludes pending rows with empty text.
The CPU repair made deferred transcription normal without updating this panel.

The user confirmed both Timeline and Live were affected. Installed UI inspection
showed Live displaying older readable speech blocks while fresh recordings were
absent. Live's status read already included pending rows, but its status panel
was not inserted into the active view, and its presentation mapping discarded
the recorded media path. This is a second display path, separate from the
Timeline query omission.

Read-only checks on 3 October confirmed new pending rows and files advancing
every ten seconds. A sampled file passed native `afinfo` inspection with
240,085 valid frames at 16 kHz (15.005313 seconds), plus separately reported
encoder priming/remainder. It decoded successfully and contained a signal.
This is a sampled-file check, not an audit of all historical recordings or
proof of speech content. The installed capture configuration records the
microphone; system-audio capture is disabled by its existing default.

The transcription backlog is a separate freshness problem. Some older work
has completed: rows inserted since the 1 October installation included sixteen
transcribed rows and two needing review at the follow-up check. The latest
transcribed write was on 3 October at 02:49 AEST for a June recording.
Recordings from 2–3 October remained pending. The queue selects oldest pending
audio first; the current UI reported waiting for the Mac to be less busy.
These observations do not establish which admission condition dominated
overnight. No global processing override or power setting was changed.

## Repair scope

The repair is isolated in `/Users/stuartbond/backintime-hotfix-cpu-guard`.
The audio panel loads saved pending/activity rows through one shared bounded
reader, keeps their original playback references and reports pending text.
It refreshes a visible stationary selection without automatically playing,
transcribing, changing stored evidence or raising the window. Initial-open
and refresh lifetimes reject cancelled or replaced selections. Large loaded
ranges disclose omitted rows.

The Live extension adds a bounded recent saved-recordings section with explicit
playback and pending-text labels. Its reader/player lifetime follows visibility;
completed transcript history remains separate and historical labels include the
date so older speech cannot appear current merely because the time of day matches.
The Live read examines twelve newest audio entries plus one overflow sentinel,
shows entries with retained media paths, and discloses that limited scope. It
refreshes every eight seconds only while the Live section is visible. Cancelled
reads stay owned until completion before a replacement read can start.

## Verification and delivery

The final focused debug run passed **94 tests, zero failures or skips**: seven
Live saved-recordings regressions, 68 existing dashboard presentation checks,
nine transcript cursor/presentation checks and ten Timeline visibility/lifetime
regressions. Tests use real private SQLite and a byte-pinned authored AAC through
the native reader and muted player. They cover pending text, exact playback
ranges, unchanged stored bytes, completed-text refresh, deletion, mixed pages,
bounded reads, cancellation, close/reopen and replaced providers. Opening either
surface starts no transcription or playback. Independent source review is clear
after reproducing and fixing delayed-open, cancelled-read ownership and partial-
page disclosure issues. The sleep API guard and `git diff --check` pass.

A later, test-only native rendering probe is explicitly opt-in with
`RETRACE_TEST_NATIVE_AUDIO_VIEW=1`. It mounts the real Live component in a
nonactivating offscreen panel and attempts to read its date/status and press its
native accessibility Play control. In this execution session the fixture exposed
only hosting/graphics/focus proxy nodes, with no usable authored controls.
The failure is retained in `live-native-view-offscreen.log`; **rendered UI and
native control acceptance are not established**. An unopened-panel attempt and
an initial test-helper compile error are also retained. The default opt-in guard
compiled and passed with one intentional skip, zero failures. No product source
changed after the 94 passing checks or optimized compilation. This extra probe
is not counted as another passing behavioral test.

Reproduction in the isolated hotfix worktree:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
RETRACE_TEST_DISABLE_FILE_LOGGING=1 \
RETRACE_AUDIO_VISIBILITY_FIXTURE_AAC=/Users/stuartbond/backintime/docs/fixtures/unified-history/speech/fixtures/au-names-padded.m4a \
/usr/bin/nice -n 15 swift test -j 2 --enable-code-coverage \
  --filter 'RetraceTests.DashboardSavedRecordingsTests|RetraceTests.DashboardVoiceLayoutTests|RetraceTests.TranscriptRecordingVisibilityTests|RetraceTests.TranscriptCursorPolicyTests'
```

The fixture SHA-256 is
`12d984dc71bad6e5bacab2f8fceb4423911a46e7ae5a23c9c1c41c349f8830dd`.
The override is explicit and byte-checked; without it the new test fixtures use
the production AAC writer.

The optimized product build passed in **393.37 seconds**, at nice priority 15
and two build jobs. This is an incremental rebuild using the separately clean
1 October optimized cache; the change is confined to UI and changes no Shared
or module protocol layouts. The prior executable and all fifteen resource files
were preserved before cache reuse. The new unbundled executable is retained in
`Verified unbundled release/`, with SHA-256
`b4a5717355e8a3317cb0cf6f6f1054579e313f3d70293cdf8f0b170ea2b89d85`.
All fifteen resource files match the prior release. Product source hashes match
the independently reviewed freeze. This establishes compilation, not signing,
installation or the broader performance target.

An optimized build of the Timeline-only scope was deliberately interrupted
when the user's clarification added Live; its exit-130 receipt is retained as
`release-timeline-only-superseded.log`, not a passing build result.

The current command environment cannot create AAC through the unchanged
production writer: both the new fixture setup and an untouched playback
control fail with AVFoundation error 1718449215. The explicitly supplied
authored AAC fixture preserves the native decoding/playback check without
silently treating the writer as passing. A broader `Transcript` filter matched
82 tests across multiple modules, with two skips and twelve failures involving
AAC fixture writing, native Speech metadata and processing backpressure. Only
the AAC writer failure was separately reproduced in the untouched control;
that broad run is not an all-green or fully explained baseline receipt.

**Not installed.** The running app remains 2610.1.1. This execution session
finds no signing identity in the configured login or system keychains and
cannot validate the installed bundle's signature. Its executable SHA-256 and
Info.plist still match the retained, previously verified 1 October candidate;
no bundle alteration is inferred from the unavailable signing check.
Computer Use denied the Terminal application for safety reasons, so that
fallback cannot perform a signing check. A native signing/verification session
is required before replacement. Recording has been left running.

Private diagnosis receipts are under
`~/Library/Application Support/Retrace Candidates/2026-10-03-audio-visibility/`.
Test receipts originate under `/tmp/retrace-audio-visibility-20261003/` and are
retained in that private delivery directory. Reviewed packaging/installation
helpers are prepared there, but syntax/static review is not native execution
or installation acceptance. The larger, dirty V24–V32 workspace was not
installed or overwritten by this repair; integrating this UI fix with its
separate exact-media playback contracts remains a distinct source task.
`NATIVE-DELIVERY.md` in the private delivery directory contains pinned commands
for a signing-capable Mac session. Packaging, normal Quit, guarded replacement,
recording restart and installed UI acceptance are separate steps; source/build
success does not authorize a claim that the repair is already running.
