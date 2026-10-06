# Recent audio transcription repair

## Observed failure — 6 October 2026

At 14:07 AEST the installed app remained **0.7.6 (2610.1.1)**, source
`f1551beee4ee2e64a4e2642aec7c8c99e315b8c9`, with executable SHA-256
`fe0fe21736e62842d26b54606fd02413a3b0acf702057cbc0e00ae1364d93c90`.
The native library remained V23. The 3 October saved-recordings display repair
had not been installed.

Read-only checks found 7,662 microphone recording rows from the preceding
24 hours, all pending. The eight newest referenced files existed and matched
their recorded sizes. At 14:10 the later count was 7,680. One newly saved file
passed native `afinfo` inspection (240,086 valid frames at 16 kHz, 15.005375
seconds, with priming and remainder reported separately) and decoded through
ffmpeg with a nonzero signal. This is a sampled-file check, not a speech-quality
or complete-history audit. No recording, setting or history row was modified.

Text preparation was making some progress on old recordings: new transcript
rows written at 13:15–13:16 on 6 October belonged to audio recorded on
3 September. The latest recording timestamp with a `transcribed` row was
1 October at 17:43:17 AEST. Those are different clocks; recent database writes
do not imply fresh captured speech is being transcribed.

The governed first-pass worker requested one row from
`getUntranscribedBatches(limit: 1)`, which orders all pending and repair work
oldest first. Quiet-time admission therefore spent its available budget on
historical audio before reaching current recordings. The installed Timeline
also filters empty pending rows, and Live omits its saved-recordings panel.
These are separate scheduling and presentation defects. The prior display
repair alone does not repair queue freshness.

The installed System Monitor reported recording with text preparation waiting
for the Mac to be less busy. Its CPU monitor is active; these observations do
not establish a matched performance result or the 20% active-use target.

## Narrow source repair

Work is isolated in `/Users/stuartbond/backintime-hotfix-audio-freshness`, based
on display-repair commit `1ff32f446e6a2d5af5a0d6a0af7b1b515a0f6e47`.
The original display candidate and its clean source worktree remain available.
The combined queue/display candidate is the preferred next delivery; do not run
the older display-only installer in parallel with it.

The implemented governed queue policy prefers the newest first-pass pending
recording within the inclusive last 24 hours. After three recent attempts it
selects the oldest retained pending/repair recording, preserving historical
progress. An attempt that fails or is cancelled still consumes its scheduling
slot so a failed old recording cannot monopolize every subsequent admission.
No recent candidate means falling back to oldest work immediately.

This changes ordering after admission. It does not start inference during
active use, relax CPU/pressure limits, change Whisper threads, enable system
audio, alter codecs, rewrite history, or change explicit manual backfill.
Saved media remains durable; existing exact completion, cancellation and
deletion checks continue to govern publication. The rolling horizon is a
priority hint, not a deadline or promise of real-time transcription.

## Validation and installation

The first native AAC worker fixture failed during PCM decoding with AVFAudio
error 1718449215 before reaching queue assertions. A separate unchanged-decoder
control opened both authored fixtures: the AAC PCM read failed, while the
bundled authored WAV read all 171,707 frames. Ordinary worker regressions use
that real WAV through the unchanged production decoder with honest `.wav`
paths. The explicit AAC override remains a failing native check in this command
session; it is not silently skipped or treated as successful AAC acceptance.

The subsequent meaningful RED run executed 20 tests with 32 expected assertion
failures and no unexpected failures. It reproduced oldest-first selection ahead
of new recordings through actual native WAV decoding and canonical SQLite
completion. Its 20,000-row SQL fixture recorded 260,056 virtual-machine steps
and temporary ordering for the prior lookup. The implementation now uses
separate status-indexed single-row queries and compares the two oldest status
candidates by their exact integer timestamp and ID. Result size is bounded;
residual batch-path filtering can still inspect more than one index entry.

A separate read-only check of the new query shapes against the live V23 store
selected a 6 October 14:26 recording for the recent lane and a 3 September
recording for the oldest lane. All three selectors used the existing status/time
index without a temporary sort and completed in under 1 ms in that one sample.
That was Python SQLite 3.51.0, not the App worker or a matched performance test.

After `swift package clean`, the focused debug run passed 152 tests, with one
intentional opt-in native-view skip and zero failures (153 selected). This covers
the new SQLite/worker cases, exact pending commits, governor/resource regressions
and prior saved-audio presentation checks. Two final test-only additions then
passed in the 22-case query/worker selection: complete timed words and canonical
media ranges across reverse overlapping recent windows and an old-lane hop;
and joined shutdown while cancelled native inference retains a cleanup tail.
Neither controlled inference output nor the WAV decoder establishes Whisper
recognition accuracy or native AAC worker acceptance.

The 20,000-row fixture uses 31 SQLite VM steps for recent selection and 25 for
each oldest-status query (81 across all three), without a temporary sort. This
is a query-shape regression, not a whole-library or end-user latency claim.

A separate empty-scratch optimized product build passed at 14:40 AEST in
365.04 seconds with two build jobs at reduced priority. All 378 pinned product
inputs matched before and after compilation. The preserved unbundled executable
SHA-256 is `f6c12cf4e41361060263f3c523a9ce82d16cdabbbb2654df3a1fe2e4a2628290`.
Independent product/test review found no remaining issues. Source checks,
native signing, installation and installed acceptance remain separate.

The Codex command session again reported zero valid signing identities and
failed strict verification of the existing app. The user confirmed that their
normal Terminal lists a valid identity and completed packaging there. The
combined **2610.6.1** candidate includes the display and queue ordering repairs;
all 39 compiled payload sections match the reviewed executable. No signature
check was bypassed.

The reviewed private delivery helpers retain the old app and quiescent database
before installation. The installer verifies the bundle actually moved before
placing the candidate and never overwrites an app that another installer has
placed at the destination. Five private native-filesystem swap cases pass; their
verification boundary is controlled and does not establish native signing or
full installation acceptance. Abrupt process termination and initial move
bookkeeping are outside the caught verification/staging recovery guarantee.

## Installed local trial — 6 October, 23:19 AEST

The user's first normal-Terminal install stopped at `writer_present`: an
independent SSH-origin `sqlite3_rsync` process still held the database/WAL open.
Retrace had quit correctly. That copy was left intact, the old app was reopened,
and installation was retried after the copy completed. This first quit/reopen
left **232.927 seconds** between saved audio ranges.

The retry passed native verification and retained both the old app and a
quiescent database rollback copy. The installed executable hash is
`460f9aa4a52be94d1f857f5197f42c5faa1a83c82c618bee9d43a666fedc0c62`,
build **2610.6.1**, source `50778412480d6ba98651a1904edb617fb59418bf`.
The installer made no library writes. Post-launch reads confirm V23 and the
same persisted recording, context and exclusion settings. The command-session
`defaults` view omitted these native-domain keys; the user's persisted plist
was checked directly instead. The successful installation's quit/reopen gap
was **210.012 seconds**, from 23:16:13.447 to 23:19:43.459.

The native app opened the Studio Display microphone at 23:19:43.217. New AACs
contain nonzero PCM. Fresh pending recordings at 23:22 are visible in Live and
Timeline. Explicit Play reached the playing/pause state in both surfaces;
Timeline pause reached Resume, and closing the player ended the check.

A brief explicit Process now check ran the installed AAC decoder and CPU
Whisper path, completing a fresh 23:26:53 recording as `probable_silence` with
empty text. The override was cancelled, and the UI returned to waiting for
lower load. This proves recent native queue progress without inventing text;
it does not prove new spoken-phrase publication or recognition accuracy. The
earlier local spoken-test recognition and microphone-routing diagnosis are
recorded separately in the [microphone ledger](microphone-input-repair.md).

The wider dirty V24–V32 workspace remains untouched and uninstalled. Physical
input-switch acceptance, matched CPU/latency, longer catch-up throughput and
the 20% CPU target remain open. `installed-acceptance-20261006.json` preserves
the bounded checks and these limits beside the native installation receipts.

Content-free diagnostic receipts are retained under
`~/Library/Application Support/Retrace Candidates/2026-10-06-audio-freshness/`.
