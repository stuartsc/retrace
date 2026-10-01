# Installed-version CPU protection repair

## Problem and scope

On 1 October the installed **2609.29.1** app still ran live CPU Whisper without
the source candidate's shared governor. The user's Activity Monitor showed
215.8%; a fresh process reading showed 183.3%. A three-second native sample
confirmed `processLiveTranscriptionQueue` → `processPersistedBatch` →
`whisper_full` → the CPU graph. These are intermittent observations, not a
matched performance benchmark.

This repair starts from V23-compatible `52f12be` / `7aab20a` in the separate
`backintime-hotfix-cpu-guard` worktree. It adds the tested CPU sampler and
governor, durable pending-audio scheduling, native inference cancellation and
joined manual repair ownership. Existing audio codecs, Whisper models, screen
capture/OCR settings, privacy rules and history schema remain compatible.
The larger V24–V32 storage/capture candidate is outside this installation.

Audio saves before inference. Automatic first-pass transcription and repair
wait for five minutes without input and acceptable load/pressure. Input
inactivity is only a scheduling hint. The governor admits one expensive audio
job, uses two Whisper threads in Low Power Mode and four otherwise, respects
macOS background scheduling, and cancels interruptible automatic inference on
renewed interaction. Cancellation leaves pending work eligible. Explicit
dictation retains the direct transcription service. Existing low-rate screen
OCR is unchanged in this emergency slice.

The System Monitor separates recording from audio text preparation, explains
deferral and exposes a cancellable Process now override. CPU values use
100% for one logical core; whole-Mac percentages use all cores. The sampler
runs independently of views, with bounded rolling windows and joined,
content-free minute delivery. Missing observations remain unknown. These
admission thresholds are not a hard process CPU cap.

## Validation and delivery ledger

**Source and signed package are verified; installation is pending a normal
app quit.** This document does not establish installed performance acceptance.
The first behavioral run demonstrated 25 expected
failures across 48 tests (one intentional skip). The initial implementation
then passed 54 focused tests with two native opt-in skips. Review identified
shared-connection transaction ownership and exact integer-timestamp preservation
as required follow-up fixes before final validation. Initial clean compilation found adapter/protocol and
constructor integration errors; the failing receipt is retained at
`/tmp/retrace-cpu-guard-20261001/red.log`. Regression tests cover native AAC and
private SQLite persistence, cancellation/restart, atomic publication, deletion,
repair eligibility and shutdown ownership.

Private delivery material is under
`~/Library/Application Support/Retrace Candidates/2026-10-01-cpu-guard/`.
The prepared installer verifies the current app, requires normal shutdown,
retains the prior app and clones a quiescent database plus durable sidecars.
It does not modify or copy live media and makes no history schema transition.
Normal restart necessarily creates a recording gap; its observed duration and
post-launch capture advancement must be recorded separately.

The temporary priority reduction applied to PID 39830 ended when that app was
quit at 15:58:49; it was reapplied to relaunched PID 87637. This is temporary
scheduling preference, not CPU protection acceptance. Global power settings
were not changed.

### Completed source and package checks — 1 October

- Implemented source: `f1551beee4ee2e64a4e2642aec7c8c99e315b8c9`, branch
  `fix/installed-cpu-governor` in `/Users/stuartbond/backintime-hotfix-cpu-guard`.
- A fresh `swift package clean` followed by the full instrumented debug suite
  passed **1,137 tests, nine intentional skips, zero failures**. A separate
  run using the installed small Whisper model passed all five native/model
  tests, with no skips. Native token revocation joined in **0.0595385 seconds**
  and the same model remained usable. These cases use authored audio.
- Combined line coverage is **90.7%** across the new governor, sampler,
  admission, ownership and persistence files; this excludes UI and legacy
  audio files. Coverage is a source check, not a live performance benchmark.
- A separate empty release scratch directory produced a clean optimized
  build in 1,189.91 seconds. Source, native inputs and dependency pins matched
  their pre-build hashes. Compilation ran with two jobs and reduced priority;
  macOS refused a later attempt to increase that priority, so it stayed at 15.
- Signed candidate **0.7.6 (2610.1.1)** has executable SHA-256
  `fe0fe21736e62842d26b54606fd02413a3b0acf702057cbc0e00ae1364d93c90`.
  The unbundled build SHA-256 is
  `fb767eb6388af11f165ef0c40905564a27f7c46c3e2a51ba0ad8786156091411`.
  All 39 executable sections, header properties and non-signature link-edit
  bytes match; 15 resource files match their build receipt. Entitlements and
  designated requirement match the installed app. Six native libraries match
  their tested section/header/link-edit payloads. Development library search
  paths are absent; strict deep signature verification passes.
- The old app reopened at 17:05:44 as PID 76643. Its temporary priority was
  reduced to 10. A later one-minute observation ranged from 116.6% to 186.1%
  CPU; compilation/tests were also active, so this is not a matched baseline.
- The app had not been replaced as of 17:40. macOS UI automation repeatedly
  timed out in both Retrace and Activity Monitor; a normal manual quit was
  requested. No forced termination was used. The old app is still recording.

Private receipts include `source-verification.json`, `release-complete.json`,
`package-verified.json`, `payload-comparison-review.json` and the retained
`Validation/` logs under the delivery directory above. Live CPU comparison,
recording advancement, settings/schema checks and installed UI acceptance
must follow installation; none is inferred from these source/package checks.

## Scope limits

- The governor controls audio inference in this V23 repair; OCR and storage
  redesign remain in the larger candidate.
- Process now in System Monitor requires recording to be active. While paused,
  Settings' Transcribe Saved Audio runs a bounded explicit repair. The global
  override remains cancellable while paused.
- Failed AAC or pending-row writes retain the prior immediate fallback and now
  show a storage warning. This is not a new guarantee of durable recovery from
  persistent write failure; stopping can discard unsaved fallback work.
- The 20% active-use CPU figure is a target and admission threshold, not a hard
  process cap. Representative matched workload and foreground-latency acceptance
  remain separate from automated scheduling and native cancellation checks.
