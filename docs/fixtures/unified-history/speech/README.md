# Authored speech comparison fixtures

These retained PCM/AAC files exercise names, amounts, negation, silence padding
and controlled overlap. They contain no user recording. `manifest.json` binds the
exact bytes; the original creation and native codec receipts remain alongside
the two independent source texts. Both tracks use the same synthetic Australian
Karen voice at different rates. This is not a human, accent-diversity,
diarization or independently annotated word-timing acceptance corpus.

The existing negation/status input remains in
`Processing/Tests/Fixtures/WhisperTimedWords/`. No copy is needed here.

Use the explicit macOS 26.2 SDK and `RETRACE_TEST_DISABLE_FILE_LOGGING=1`. Build
matching tests first. `NativeSpeechTranscriptionServiceTests` takes absolute paths
in `RETRACE_SPEECH_BENCHMARK_AUDIO_PATH` and the optional
`RETRACE_SPEECH_BENCHMARK_REFERENCE_PATH`. Batch comparison additionally requires
`RETRACE_SPEECH_BENCHMARK_WHISPER_MODEL_PATH` to an explicitly selected model.

- `testCompareNativeSpeechWithCPUWhisperOnExplicitAudio` compares native en-AU
  batch recognition with CPU Whisper on the same decoded PCM.
- `testInstalledNativeStreamingComparisonKeepsFinalSpansAndReportsProgress`
  supplies paced 0.25-second native chunks. This is not a Whisper streaming test.
- `testInitializationChecksConfiguredModuleAssets` reports exact batch and
  streaming asset status. A passing missing-assets rejection is not readiness.
- `RETRACE_SPEECH_BENCHMARK_INCLUDE_TEXT=1` includes hypotheses, timed spans and
  volatile updates in the explicit comparison's stdout. Use it only for intended
  benchmark inputs; normal scoring omits recognized content.

Keep `RETRACE_SPEECH_BENCHMARK_PREPARE_ASSETS` unset for read-only asset readiness.
Use `oracles/au-names.txt` for all names/padding variants. The deliberately empty
`oracles/silence.txt` declares expected silence; a missing reference means unscored.
For overlap, leave the reference variable unset: there is no defensible single
word ordering. Preserve per-track text/offsets from provenance rather than
inventing diarization or a total transcript.

Raw WER treats written numbers and digits differently. Inspect amounts, names,
status and negation separately in the exported hypothesis. Controlled runs under
host contention establish neither latency/energy superiority nor the foreground
p95 requirement. Model inference and comparison outcomes are recorded separately
in the unified-history delivery ledger; fixtures alone prove neither accuracy
nor promotion readiness.
