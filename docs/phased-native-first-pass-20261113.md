# Phased native first-pass candidate — 13 November 2026

## State and gates

Source work in `repair/phased-transcription-20261113`, isolated from the frozen
responsiveness repair and the installed app. No installation, live preference,
model download, capture device, playback or foreground automation was used.
Apple speech assets are unavailable on this Mac; download approval is pending.
No native accuracy, continuous coverage, latency, energy or memory claim follows
from controlled fixtures.

Both `liveMicrophoneDraftTrialEnabled` and the separate
`nativeFirstPassReuseTrialEnabled` default to false. The latter is an internal
candidate gate, not a promoted Settings option. Preview can be evaluated alone;
canonical native reuse must pass its additional acceptance first. System audio
retains CPU first-pass transcription because it has no proven sample lineage.

## Implemented boundary

1. Existing microphone PCM feeds the independently bounded native subscriber.
   Source generation/continuity and sample coordinates are preserved.
2. After AAC and its pending SQLite row commit, a bounded digest and one complete
   source range form an ephemeral proof. The voice-marker persisted callback is
   unchanged. At most 64 proofs are retained; eviction or restart loses only the
   optimisation. The media and pending queue stay durable.
3. The admitted first-pass worker decodes AAC, checks frame count and digest, and
   requests native finalization through the batch's exact source endpoint. Its
   bounded one-second coverage wait cannot delay capture ingestion or saving.
4. Only ordered `resultsFinalizationTime` events advance native coverage. Neither
   final words, silence, wall-clock estimates, volatile range nor method return
   counts as processed sample coverage. Cross-window text requires complete native
   timed tokens and no token cut by the boundary. Partial coverage uses CPU.
5. After file revalidation, the existing exact-row transaction publishes nonempty
   native text as `needs_repair` with `first_pass_repair_pending_v1`. Existing FTS
   hooks and notifications expose it immediately; a later ambient permit owns CPU
   correction. Native-origin repair explicitly makes one raw CPU comparison;
   an empty/worse correction cannot erase retained text. No duplicate fresh CPU
   inference is needed for a covered batch.
6. Cancellation, deletion and changed media invalidate publication. Recording
   remains available. Microphone inactivity retires and joins the native owner
   after five seconds (checked every two seconds), shows waiting for microphone,
   and avoids restarting a model until a new microphone packet arrives.

The saved row remains a full recording batch. This change makes no new claim
about sample-accurate navigation within its transcript, source speaker identity,
non-overlapping audio storage or installed performance.

## Issues resolved and remaining

- Native result-stream termination previously published coverage through the
  last input before the analyzer task's success was known. Terminal coverage now
  follows successful joined completion and is bounded by the native consumed
  endpoint; cancellation/failure cannot manufacture a tail acknowledgement.
- Keeping native preview and fresh CPU inference in parallel would not establish
  hardware efficiency. Covered results can now be reused, with CPU correction
  moved to the existing separate repair lane. Missing/late coverage still costs
  the CPU fallback; that behaviour is visible and intentionally retained.
- Apple's documented `finalize(through:)` returns after publishing results, but
  the app may not yet have consumed those results. The implementation therefore
  waits for the ordered result event, not the finalization task's return.
  Source: <https://developer.apple.com/documentation/speech/speechanalyzer/finalize(through:)>
- Native continuous acknowledgement at the saved batch endpoint must be proven
  with installed assets. `LiveTranscriptionNativeTests.testNativeFinalizationCoversAuthoredPCMWhileInputRemainsOpen`
  requires `RETRACE_NATIVE_FIRST_PASS_COVERAGE_TEST=1`, replays only the pinned
  authored WAV, never downloads assets, and fails if coverage misses the bounded
  wait before input closes. Silence/late native acknowledgement may limit reuse;
  CPU fallback must remain until the real measurements establish behaviour.
- All acoustic quality, Australian names/numbers/negation, overlap/timing, helper
  memory and whole-system energy comparisons remain acceptance work. No codec,
  history, power setting or system-audio lineage was changed.

## Verification record

- Swift parser checks and `git diff --check`: passed during implementation.
- Added `NativeFirstPassCoverageTests` for explicit barriers, partial range/token
  safety, stale source, correction, continuous open-input finalization, bounded
  fallback, pause and microphone stop/restart.
- Added `NativeFirstPassPersistenceTests` using native AAC encode/decode and a
  private on-disk SQLite database: searchable retained text without fresh CPU,
  reopen/quiet-time correction, missing/system fallback, cancelled waits, stale
  proof, deletion and a changed AAC while waiting.
- Focused debug validation passed: **78 tests, 2 explicit opt-in skips, 0 failures**,
  21.194 seconds test execution. The successful receipt is
  `/tmp/retrace-phased-native-retry1.log`. Dependencies and all targets were built
  from an initially cleaned scratch directory; the compile-only correction below
  was then rebuilt in that scratch directory. It is not an untouched first-run
  clean-build receipt. The source checkpoint follows this validation.
- The two skips are the Apple-native authored draft/continuous-coverage tests.
  They were disabled by the safe runner, not passed with a substitute model.
  The parent session's earlier check reports native en-AU assets missing; this
  candidate did not download or recheck them. Controlled output validates the
  persistence contract, not actual speech inference.
- Separate optimised build, full-suite expansion and the parent's single advisory
  review remain pending. No installation or deployment occurred.
- Fast preview and durable latency are different gates: publication still runs
  in the existing governed first-pass worker. Admission delayed beyond the
  60-second coverage ledger safely falls back to CPU, so low durable latency
  under sustained load is not yet demonstrated. Current gating also requires
  the ordinary CPU service to be available; this is not a native-only product.

### Initial clean compile diagnostic

The initial clean run failed in `NativeFirstPassCoverage` because its mutating
array removal called an instance helper, creating overlapping Swift exclusivity
accesses. The stateless overlap helper is now static. The failed receipt remains
at `/tmp/retrace-phased-native-clean.log`; the retry uses a separate log. This is
a compile correction, not native acceptance.

### Advisory review

The one advisory review of `e90fcc7..0ea09c9` found no blocking correctness or additional medium-severity defects. It covered coverage/finalisation, exact AAC binding, cancellation, device inactivity, durable publication and deferred CPU correction. This is source review, not native acceptance. Both native gates remain disabled. Full logs are retained under `docs/fixtures/repair-20261113-native`.

### Full noninteractive regression

The full suite passed1,733tests,24explicit skips,0failures in568.024s. Swift/native inputs remained unchanged from0ea09c9. The already-reviewed runner environment fix was inherited to clear legacy interactive switches; its Python test passed. This reliability run is not a matched performance comparison or native speech acceptance. Complete compressed log and hash are retained with the focused receipts. Separate clean optimised validation will follow integration of the independently validated AAC writer option.
