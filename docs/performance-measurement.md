# Retrace performance measurement and promotion

Status: developer scorecard and comparison tooling implemented; representative
installed acceptance remains required. No targets are claimed met by this document.
The installed application, source candidate, native fixtures and runner self-test
are different evidence scopes.

The scorecard command and complete versioned input contract are documented in
[`scripts/performance_benchmark/README.md`](../scripts/performance_benchmark/README.md).
The runner is offline and does not inspect the production library. It imports
existing native OCR, Whisper/Speech, codec, cancellation and retrieval exports as
explicitly scoped evidence. Only three or more independent complete matched
representative runs can pass a promotion comparison.

## Four dimensions, with recording health as a prerequisite

| Dimension | Required measurements |
| --- | --- |
| Quality | OCR CER, speech WER, literal critical tokens, exact screen/audio navigation, timestamp correctness |
| Speed | Capture-to-search, keyword/results-display and foreground p95; cancellation, archive encoding/decoding and seek p95; completed work/backlog recovery |
| Cost | Actual process CPU-seconds per observed recorded hour and per query; measured peak memory; retained archive bytes/hour; full index/model footprint; measured energy only when available |
| Intelligence | Macro Recall@1/3/5, MRR, exact source correctness and unsupported-result rate on frozen temporal/paraphrase/cross-source queries |

Before measuring improvements, verify screen and audio progress independently.
Stopped audio, excluded captures, hidden gaps, missing metric samples, low-disk
interruptions or an increasing backlog cannot become a CPU/storage win. Count all
capture attempts and every foreground, cancellation, encoding, decoding and seek
attempt. Pin their denominators and leave unfinished latency observations explicitly
unavailable.
Do not recategorize slow first-pass work as historical work and remove it from the
freshness denominator.

Process CPU uses monotonic deltas of user+system CPU time, with 100% representing
one logical core. Load average is a supplementary pressure signal, not CPU usage.
Async job wall time is not CPU attribution; overlapping work needs whole-process
accounting, explicitly scoped isolated measurements and an unattributed remainder.
Shared Apple Speech helpers and whole-system energy must be measured separately.
Unmeasured energy stays unavailable and never becomes zero or inferred savings.

Storage comparisons use the same recorded duration, corpus, container overhead,
index/reference requirements and codec workload. Logical bytes, allocated bytes,
APFS clone totals, free disk space and actual reclaimed bytes are different values.
Compare original-spool pressure separately from retained archive growth.

## Before a performance-sensitive change

Freeze the workload, reviewed corpus/oracles, relevant source/resources, model
artifacts, configuration, device/OS, power mode and cold/warm state. The same
conditions apply to baseline and candidate, with only the declared treatment
changed. Preserve failed runs and raw fixtures. If a corpus oracle needs correction,
create a separately frozen version before scoring candidates.

Attach the affected benchmark receipt to the change:

- Capture, OCR or compression: exact pixel/media checks, critical text and CER,
  capture-to-search, capture coverage, CPU and retained bytes on the same scenes.
- Speech or audio storage: names/numbers/quiet speech/overlap, WER and critical
  tokens, timing/playback, native AAC decode and frame/sample continuity.
- Search or intelligence: literal identifiers first, complete scoped queries,
  Recall@K/MRR, source revalidation, keyword and visible-results p95.
- Scheduling, lifecycle or monitoring: CPU accounting, active/idle paired loads,
  resumed input/cancellation, no starvation, sleep/wake and shutdown/restart.
- UI changes: foreground latency with search/timeline navigation and settings
  storage validation; collector overhead belongs in the measured workload.

Existing native fixtures are reused through read-only import adapters. The small
OCR and speech fixtures do not establish representative storage, foreground
responsiveness or installed performance. The eight-screen recall v1 Q11 ambiguity
remains explicitly documented. A successful build or ordinary skipped native test
does not supply a missing measurement.

## Before promotion

Run the full scorecard with real Vision, AAC, SQLite, native screen capture and
archive decoding. Include dense native text, tiny/coloured text, digit/negation
changes, scrolling/static screens, photographs/video, multiple displays,
Australian speech and overlap. Include explicit lifecycle evidence for
sleep/wake, restart, exclusions, low disk, deletion during reading, failed writes
and shutdown with pending work. Use a healthy baseline; investigate capture
stoppages before claiming an improvement.

For a CPU-governor promotion, require at least 50% lower active-use CPU-seconds per
recorded hour, with every matched run passing. Report progress toward the existing
20%-of-one-core soft target separately. For a codec promotion, require at least
20% fewer retained bytes on the identical workload. In both cases require no
critical-token, exact-navigation or source errors; no CER/WER/recall regression;
no hidden gaps or growing backlog; foreground p95 within 10% of baseline; and no
material archive/timing regression. The comparison uses a 10% ceiling for measured
archive encoding/decoding/seeking, cancellation, query CPU and peak memory.
Unrelated CPU/storage growth and paired measured whole-system energy also have a
10% ceiling; a CPU win cannot conceal a storage regression or vice versa. Initial
backlog count and age must match, and receipts cannot be reused across both sides.

Normal-load capture-to-search p95 must be at most 10 seconds, warm keyword search
p95 below 100 ms, and visible-result p95 at most 250 ms. Complete-work rate must
retain at least 90% of the matched baseline while pending count/age do not grow.
Run at least three independent repetitions; every pair must pass. Report first-run
pass, any-pass-in-three and all-three stability separately. A good average or best
attempt is insufficient. Mixed/missing hardware, OS, model, corpus, workload or
configuration identities make a result non-comparable, not a pass.

Native XCTest/Instruments measurements remain an independent verification of CPU
and elapsed time. Whole-system energy and helper-process memory require their own
explicit receipts. The Python self-test verifies orchestration and thresholds;
it cannot establish these native results. Command-runner SIGINT/SIGTERM regression
tests use actual child/descendant processes and require owned-group termination,
leader reaping and an interrupted receipt before return; this proves runner
lifecycle behavior only.

After protocol/actor changes, perform a clean debug validation and a separate
clean optimized build. Keep source verification, installed build identity,
controlled rollout and actual user acceptance as distinct receipts. A scorecard
passing its declared gates does not authorize installation or establish acceptance.
No bulk history recompression or automatic history deletion is introduced here.

## Retention and review

Production monitoring should retain bounded, content-free aggregates for 30 days;
source text/audio does not belong in metrics. Frozen benchmark reports, artifact
hashes and raw native receipts belong with the release evidence and are not
subject to that diagnostic retention window. Compare the four dimensions directly,
without one combined score that conceals a quality or recording regression.
