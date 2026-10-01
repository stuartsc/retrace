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

Work is in progress; this document does not establish installation or measured
performance acceptance. The first behavioral run demonstrated 25 expected
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
