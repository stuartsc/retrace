# Retrace performance scorecard

Offline Python 3.11+ tooling; the standard library is sufficient. It collects
measured sessions, compares matched runs, imports existing native fixture exports
and executes explicit authored command plans. It does not inspect the installed
library, start a model, download anything, change preferences or automatically
start SwiftPM.

A passing comparison is a calculation over supplied native receipts. It is not
installation, release or user acceptance. Source, corpus and measurement receipts
must be independently reviewed. The synthetic values in the tests exercise rules;
they are never Retrace performance measurements.

## Commands

Run from the checkout. All output/scratch directories must be new; existing paths
are refused. Their parent directory must already exist.

```sh
python3 -m unittest discover -s scripts/performance_benchmark -p 'test_*.py'

trial_dir=$(mktemp -d /tmp/retrace-scorecard.XXXXXX)
python3 scripts/performance_benchmark/benchmark.py self-test \
  --scratch "$trial_dir/orchestration"

python3 scripts/performance_benchmark/benchmark.py import-native \
  --kind ocr --variant native-refined \
  --input docs/fixtures/screen-text-quality/2026-09-20-authored-comparison.json \
  --output "$trial_dir/native-ocr"
```

The self-test really executes and verifies three deterministic child processes,
records elapsed time, reaped child CPU time, output hashes and exit status, and
labels the result `runner-self-test`. Its CPU values do not describe recording.

Collect native measurements already normalized to the contract below:

```sh
python3 scripts/performance_benchmark/benchmark.py collect \
  --input /absolute/private/baseline-session.json --output "$trial_dir/baseline"
python3 scripts/performance_benchmark/benchmark.py collect \
  --input /absolute/private/candidate-session.json --output "$trial_dir/candidate"
python3 scripts/performance_benchmark/benchmark.py compare \
  --baseline "$trial_dir/baseline/report.json" \
  --candidate "$trial_dir/candidate/report.json" \
  --profile cpu --output "$trial_dir/comparison"
```

Profiles: `cpu` requires at least 50% less CPU time per observed recorded hour
under a matched active workload; `codec` requires at least 20% fewer retained bytes
per observed recorded hour; `regression` permits no more than 10% CPU regression.
Every profile also checks quality, capture coverage, backlog, retrieval, freshness,
foreground latency, memory and decoding/seek latency. A full scorecard is required
on both sides; a partial native import cannot pass any profile.

Exit codes: `0` means the requested collection/import/execution completed, or a
comparison passed; `1` means a comparison failed/is incomplete/is not comparable,
or a command plan failed; `2` means malformed input or an I/O error; `130`/`143`
mean SIGINT/SIGTERM interruption after owned-work cleanup and receipt publication. Collection
success never means promotion. JSON and Markdown are private (`0600`) inside a
new `0700` directory. `report.json` is atomically published last as the completion
marker; a failure may leave an incomplete directory for diagnosis, which is never
overwritten. Raw fixtures remain unchanged.

## Measured session contract (v1)

The root object has `schema_version: 1`, `kind: "retrace-performance-session"`,
`scope: "representative"` or `"scoped"`, `identity`, and a nonempty `runs` array.
Unknown/unfinished measurements are not zeros. Required quantities that are
unmeasured must be collected before a complete session can be produced; use a
scoped native import for existing partial fixtures.

`identity` contains:

| Field | Meaning |
| --- | --- |
| `source_sha256` | Hash of the frozen source/resource manifest, including dirty candidate files; Git HEAD alone is insufficient |
| `corpus_sha256` | Hash of the reviewed corpus and oracle manifest; exact bytes, not filenames alone |
| `workload_sha256` | Hash of the fixed playback/actions/workload manifest |
| `model_sha256` | Hash of the exact model manifest, or the canonical empty model list for no model |
| `configuration` | Nonempty JSON object of held-constant settings: power mode, threads, displays/resolutions, backend, language, sampling, thresholds, etc. |
| `hardware` | Nonempty JSON object identifying actual device/model, logical cores and memory |
| `os` | Actual OS version and build |
| `build` | Actual evaluated build identifier |
| `phase` | Named active/idle and cold/warm workload; CPU promotion requires `active-warm` or `active-cold` |
| `treatment` | Nonempty JSON object containing only the intentionally changed feature/configuration under test |

Use canonical JSON (`sort_keys=True`, `separators=(",", ":")`, UTF-8,
`ensure_ascii=False`, `allow_nan=False`) when hashing manifests. All SHA256 strings
are full lowercase hex. Baseline/candidate source, build and treatment may differ;
all other identity fields must match exactly. Do not hide unrelated changes in
`treatment`. Model changes need their own scoped quality evaluation before a
same-model performance comparison; this tool does not waive that requirement.

Each run requires a unique `id` and unique `receipt_sha256` of its independently
retained native command/output receipt, followed by these measured fields. Receipt
hashes must also be disjoint across baseline and candidate; the same recorded run
cannot stand in for both sides:

| Fields | Units and meaning |
| --- | --- |
| `duration_seconds`, `recorded_seconds` | Positive monotonic observed wall duration and duration recording was confirmed active; never sum overlapping source/display durations |
| `screen_recorded_seconds`, `audio_recorded_seconds` | Confirmed coverage over that same observed interval, separately by modality |
| `screen_gap_seconds`, `audio_gap_seconds` | Actual interruptions, including recording stopping; zero requires coverage evidence |
| `process_cpu_seconds` | Process user+system CPU-time delta over the observed recording interval; no logical-core division |
| `query_cpu_seconds` | Separately measured query CPU-time total; do not subtract overlapping asynchronous job wall times |
| `peak_rss_bytes` | Measured peak memory with ownership/measurement scope pinned in configuration |
| `retained_bytes` | End-to-start immutable archive bytes for the workload, including necessary container/reference overhead; not APFS reclaimed space |
| `index_bytes`, `model_bytes` | Measured complete index/model footprint for this configuration |
| `energy_joules`, `energy_scope` | Both `null` when not measured; otherwise nonnegative actual energy and `whole_system` or `owned_processes` |
| `backlog_start`, `backlog_end` | Counts of pending work at both boundaries |
| `oldest_pending_start_seconds`, `oldest_pending_end_seconds` | Age of oldest pending work at those boundaries, zero only for no pending work |
| `processed_items` | Completed comparable work items during observation; preserve the same unit/workload on both sides |
| `capture_attempts` | Count of all capture attempts, including pending/failed attempts |
| `reference_characters`, `character_edits` | Frozen OCR oracle character denominator and edit count; freeze normalization/counting rules in the corpus |
| `reference_words`, `word_edits` | Frozen speech word denominator and edit count; record normalization rules |
| `critical_tokens`, `critical_token_errors` | Checked numbers, identifiers, names and negations, with literal mismatch count |
| `navigation_checks`, `wrong_navigation` | Exact source/frame/audio navigation checks and wrong outcomes |
| `timestamp_checks`, `timestamp_errors` | Original media timing checks and wrong outcomes |
| `source_checks`, `incorrect_sources` | Independently resolved returned references and incorrect/unsupported outcomes |

Counters are nonnegative integers. Reference/check denominators and capture
attempts are positive. Error counts may exceed character/word denominators due to
insertions, but wrong checked-item counts cannot exceed their check denominators.
CPU/RSS/time are measured numbers, never strings or booleans. NaN, Infinity,
overflow, duplicate JSON keys, invalid references and input files over 32 MiB are
rejected.

`latency_ms` maps each of these names to every measured outcome: `capture_to_search`,
`keyword`, `result_display`, `foreground`, `cancellation`, `archive_encode`,
`archive_decode`, `random_seek`. A required `latency_attempts` object maps every
one of those names to its positive integer attempted-event count. Each timing
array must have exactly that length; counts must match between baseline and
candidate. Use a numeric millisecond value or `null` for an
unfinished/failed/unmeasured outcome. The first array length must equal
`capture_attempts`; keyword/display array lengths must equal `queries`. A null
prevents a passing comparison and leaves that p95 unavailable; it cannot disappear
from the denominator. At least 20 observations per timing series (one for native
cancellation) and at least 60 observed seconds per run are required. Those minima
are not a substitute for a representative corpus or sustained-load assessment.

`queries` is a nonempty array of `{ "id": "Q01", "expected": ["opaque exact source
reference"], "ranking": ["opaque exact source reference", "another reference"] }`.
Use identical, source-qualified canonical identities; never bare frame numbers.
Expected sets and query IDs must match between runs. Duplicate IDs/results are
rejected. Empty rankings are real failed recall; empty expected sets are invalid.
Macro Recall@1/3/5 and MRR are recomputed, not accepted as supplied scores.

`native_coverage` is an object of independently verified booleans:
`vision`, `aac`, `sqlite`, `archive`, `screen_capture`, `archive_readability`,
`sleep_wake`, `restart`, `exclusions`, `low_disk`, `deletion_during_read`,
`failed_writes`, `shutdown_pending`. Missing/null means incomplete, false means
failed. Retain the actual native receipts behind these fields; declaring true is
not proof by itself. Supporting lifecycle receipts can be shared by repeated
workloads only when their source/configuration matches exactly.

## Comparison policy

Each side needs at least three independent runs, paired in declared order. All
pairs must pass; averages and a best attempt cannot hide a failure. `pass_at_1`
means the first pair passed; `pass_at_3` means any of the first three passed;
`pass_power_3` means all three passed. More than three runs must also all pass.
Derived values, scope/eligibility and the canonical session hash are checked again
when comparing. Initial backlog count and oldest age must match, as must every
latency attempt denominator; omitting failed or slow events cannot improve a score.

Common gates:

- Full screen/audio recording coverage; no hidden capture gaps, wrong navigation,
  timestamp/source errors or critical-token errors. The baseline must be healthy.
- No growth in pending count or oldest age. Completion throughput cannot decrease
  by more than 10%; throttling cannot manufacture savings by deferring work forever.
- No OCR CER, speech WER, Recall@1/3/5 or MRR regression.
- Capture-to-search p95 ≤10,000 ms, keyword p95 <100 ms, visible-result p95 ≤250 ms.
- Foreground, cancellation, encoding, decoding and random-seek p95, query CPU and
  peak RSS cannot regress more than 10%.
- CPU outside the CPU-improvement profile, retained archive growth, index/model
  footprint, and paired measured whole-system energy cannot regress more than
  10%. Storage savings cannot conceal extra CPU use, nor vice versa.
- The 20%-of-one-core CPU target is separately reported as a soft goal.

CPU percent is `100 * process_cpu_seconds / duration_seconds`; 100% is one logical
core. CPU-seconds/hour and retained bytes/hour use actual observed recording wall
time. Overlapping microphone/system sources do not double that denominator.
Energy is optional and explicitly unavailable unless actually measured. Only
whole-system energy on every paired run produces an energy comparison; no CPU to
joules conversion is attempted. A codec/profile pass does not grant a energy or
hardware-acceleration claim.

## Existing native adapters

| Kind | Variant examples | Source |
| --- | --- | --- |
| `ocr` | `native-refined`, `previous-scaled`, `native-documents` | `docs/fixtures/screen-text-quality/*comparison.json` |
| `whisper` | `cpu_requested`, `metal_requested` | `docs/fixtures/responsiveness/2026-09-28/whisper-comparison.json` |
| `speech` | `native`, `whisper_cpu` | `.../speech-comparison.json` |
| `codec` | `existing_quality_based`, `aac_12000` | `.../codec-comparison.json` |
| `cancellation` | No variant | `.../whisper-cancellation.json` |
| `recall` | `embedding`, `lexicalFullQuestion`, `lexicalAuthoredKeywords`, `fusion`, `rerankedPool` | `docs/fixtures/progressive-recall/phase2d/measurement-20260916/results.json` |

These yield `scope: "scoped-native-import"` and `acceptance_eligible: false`.
Missing measurements remain null. OCR operation timing is not capture-to-search;
audio inference time is not whole-system energy; fixture encoded bytes are not
continuous recording storage; shared helper memory is not Retrace RSS. The retained
recall corpus has a known Q11 oracle ambiguity; imports preserve it rather than
silently editing the raw result. Correcting that oracle requires a separately
frozen corpus. Fusion has no independently measured ranking timing in that export.

## Explicit command runner

`run --plan /absolute/private/plan.json --scratch NEW_DIRECTORY` accepts:

```json
{
  "schema_version": 1,
  "kind": "retrace-performance-run-plan",
  "pins": [
    {"path": "/absolute/authored/test-source.swift", "role": "source", "sha256": "FULL_ACTUAL_SHA256"},
    {"path": "/absolute/authored/oracle.json", "role": "oracle", "sha256": "FULL_ACTUAL_SHA256"}
  ],
  "commands": [
    {"id": "native-ocr", "argv": ["/absolute/trusted/runner", "--output", "{scratch}/ocr.json"], "timeout_seconds": 600}
  ]
}
```

Replace the placeholders with actual executable paths/hashes; this example is
schema documentation, not a fake benchmark. Pins are checked before launch and
again after all commands; failed/changed pins cannot produce completed receipts.
Commands run sequentially without a shell, in the private scratch directory, with
an isolated HOME, offline model environment switches and file logging disabled.
`{scratch}` is substituted only as literal argument text. Environment settings for
native exporters can be explicit `/usr/bin/env` arguments. SwiftPM commands must
supply an explicit package path and a separate scratch build path and must never
run concurrently with another SwiftPM command or source edits. Keep native exports
beside the command receipts, then import them separately.

There are at most 32 commands, at most one hour per command, unique simple command
IDs and refused output overwrite. Failure stops subsequent commands. SIGINT/SIGTERM are latched while work is
running: cancellation stops admission, terminates the owned process group and
reaps its leader before publishing an interrupted execution receipt. Repeated
signals do not bypass cleanup; polling reacts within the next 50 ms wait interval,
subject to OS scheduling. The first signal is retained on both the command and
execution receipts (`interrupted_signal`), `completed` is false, and post-run pin
verification is explicitly incomplete. Previous signal handlers are restored.
SIGKILL and machine/power failure cannot be intercepted. As with timed-out runs, reaped CPU totals may omit
unreaped grandchildren and are labelled accordingly. Commands are trusted authored
code, **not a sandbox**. The runner itself makes no network requests, but arbitrary
specified executables must be reviewed for local-only behavior. Never put live
library paths, secrets or captured personal content in a plan.
