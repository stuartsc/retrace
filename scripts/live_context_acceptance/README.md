# Live context acceptance measurements

This tool prepares **observations, not installed acceptance**. It does not start
Retrace, activate rules, change settings, open a microphone, request permissions,
run models, or communicate over a network. Collection is explicit and local.
The collector has not been run against the candidate as part of its unit tests.

`cpu.py` requires Python 3.10+ and macOS for collection. Tests and reports use only
the Python standard library and the system `/bin/ps` fallback described below.
No `sudo`, process argument or environment dumps,
recorded text, database contents or audio are collected.

## CPU collection

Use the **installed, signed candidate**, after its capture and playback checks.
Keep that exact executable unchanged across all four arms. Record a private
protocol document with the build hash, capture/audio settings, rules/aliases,
resource mode, power/thermal conditions, input device, workload, backlog,
companion state and evidence that other speech clients are quiet. Freeze the
common configuration; the intended difference is listener disabled/enabled.
Use separate SHA-256 hashes for the common configuration and environment.
These hashes identify operator-supplied records; the tool cannot verify them.

Run **A–B–B–A**, where A has the phrase listener disabled and B has the same
configured rule enabled through its visible Settings control. Give each arm
one minute to settle, then measure at least five minutes. Perform the same
authored speech and foreground actions in each arm. Finish all builds and
other heavy development work before starting. Do not combine sleep/wake,
input switching, offline recovery or cold model setup with the steady-state
comparison; give those separate receipts.

Example for A1 (replace the literal placeholders with recorded SHA-256 values):

```sh
python3 scripts/live_context_acceptance/cpu.py collect \
  --arm baseline --sequence 1 --seconds 300 --interval 1 \
  --protocol-id live-context-acceptance-01 \
  --build-sha256 BUILD_SHA256 \
  --matched-config-sha256 COMMON_CONFIGURATION_SHA256 \
  --environment-sha256 ENVIRONMENT_SHA256 \
  --output /private/tmp/retrace-cpu-A1
```

Repeat with `enabled/2`, `enabled/3`, `baseline/4` and fresh output paths. The
output directory must not exist. It is created as 0700, with complete 0600 JSON
files published atomically without overwriting any existing file. Parent
directories must already exist. Interrupted collection retains available raw
samples and marks the run incomplete; it cannot pass comparison.

Each run is bounded to 1–600 requested seconds, 1–5 second sample intervals,
65,536 enumerated PIDs and 256 retained processes per sample. Sampling reads
native `libproc` cumulative user/system CPU counters and process start identity.
Schema 2 also records the kernel's `kern.bootsessionuuid` and the monotonic clock
implementation. Collection fails if the boot identity cannot be read; it does
not estimate boot identity from adjustable wall time. Earlier artifacts without
that identity cannot establish a matched comparison and must be recollected.
The original and final executable hashes, Mach-O UUID and each running Retrace
image UUID prevent a replaced bundle from being mistaken for the loaded build.
CPU is **100 × CPU seconds / elapsed monotonic seconds**, as a percentage of one
core. It is not divided by the Mac's number of cores.

Some root-owned audio/ANE helpers deny native resource and task-info reads.
For already-classified helpers only, the collector may make **one** `/bin/ps`
call per sample, with at most 32 numeric PIDs and only `pid`, `lstart` and `time`
fields. It uses no shell, a fixed C locale/UTC timezone, an 8 KiB output bound
and the remaining portion of a 500 ms sample deadline. Paths are rechecked
through the native API after the call. Retrace itself and unidentified processes
never use this fallback. Denied, changed, missing or timed-out processes remain
explicit failures; no elevated permissions are requested.

Fallback records retain the UTC birth second as identity and label CPU as
`ps_time_centiseconds`: **10 ms CPU display resolution and one-second birth
resolution**. A same-PID restart within one second cannot be ruled out from
these fields. Therefore any fallback observations make acceptance inconclusive,
even when all attestations are supplied. They improve observed helper coverage,
not precision or proof of attribution. Quantized CPU is an estimate rather than
a strict lower bound; the report discloses display resolution by category.

Only the exact Retrace executable and named helpers beneath Apple's system
paths are retained. Categories are Retrace, local speech helpers, shared speech
services, shared audio (`coreaudiod`), and shared ANE services. The collector's
own CPU and its `ps` child CPU are reported separately. Process names, PID/start identities and numeric
counters are retained; unrelated executable paths are discarded immediately.
Load average supplies context, **not whole-host CPU or ANE utilization**.

The helper inventory is explicit in `SPEECH_NAMES` and `SHARED_NAMES`. Verify it
against the actual macOS SpeechAnalyzer run before acceptance. A newly introduced
helper can be absent from the inventory. Process lifetimes wholly between two
samples cannot be measured; checking or attesting this requires independent
process-lifecycle evidence. Do not simply set an attestation to true because a
run looks quiet. A process appearing/disappearing, PID reuse, denied reads,
unclassified processes, counter resets, long scans, sampling gaps and missing
Retrace all make coverage incomplete. Partial totals omit unknown CPU, including
when a helper exits before its final CPU counter can be read; quantized fallback
observations can also differ from true CPU by their display rounding.
If a cumulative counter decreases, the process's entire PID/start-identity series
is excluded from CPU totals and listed in `excluded_cpu_series` with unknown CPU.
This also applies across missing samples. A later rebound cannot count old CPU
twice; other valid processes remain measured.

## Comparison and attribution

Create a private `attestation.json` after reviewing the four runs and the
protocol. Leave a field false or unknown unless supporting evidence exists:

```json
{
  "matched_configuration_verified": false,
  "environment_matched": false,
  "other_speech_clients_quiet": false,
  "helper_inventory_verified": false,
  "no_sampling_invisible_helper_lifetimes": false,
  "no_unrelated_heavy_work": false,
  "measurement_protocol_verified": false,
  "shared_services_attribution": "unknown"
}
```

```sh
python3 scripts/live_context_acceptance/cpu.py compare \
  /private/tmp/retrace-cpu-A1/run.json /private/tmp/retrace-cpu-B1/run.json \
  /private/tmp/retrace-cpu-B2/run.json /private/tmp/retrace-cpu-A2/run.json \
  --attestation /PRIVATE/PATH/attestation.json \
  --output /private/tmp/retrace-cpu-comparison
```

Comparison weights each arm by observed duration. It reports both the
comparison's shared kernel boot session and the observation windows. Runs must
occur strictly in sequence order without overlapping scans; sequence labels
alone cannot establish A–B–B–A. Cross-boot runs, different monotonic clock
implementations, reordered observations and even matching sample midpoints
with overlapping scan edges make the result inconclusive.

The report includes both the
Retrace-plus-speech change and the change including all measured shared services;
the larger is checked against **five additional percentage points**. Decreased
unrelated shared activity cannot conceal an app/helper regression. Shared
services remain separately visible: ambiguous attribution, missing coverage,
unverified conditions, mismatched builds/configuration/environment, an incorrect
sequence or a short run makes the CPU result **inconclusive**, regardless of the
number. `shared_services_attribution: "unambiguous"` is an explicit operator
attestation, not a conclusion computed from process names. Keep the supporting
evidence with the protocol. If attribution cannot be established, retain the
inconclusive result; never subtract a guessed share of `coreaudiod` or ANE CPU.

`within_target` covers only the CPU comparison. Physical acknowledgement and
foreground latency remain `not_measured`, and overall acceptance remains
`not_established`. The broader 20% CPU goal requires its own measurement.

## Physical acknowledgement timing

Use at least 60 **physical microphone utterances**, including ordinary speech,
quiet speech, chunk-crossing phrases, two genuinely repeated utterances and
near misses. File-fed recognition is a separate functional fixture.

For every utterance retain: run/trial ID, rule revision, native source-store and
recording-generation identity, original PCM sample range/sample rate, independent
phrase start/end annotation, resulting marker ID/revision/status, durable-save
receipt and first visible acknowledgement receipt. Preserve misses, duplicate
markers, withdrawn provisional matches and unavailable timestamps in the result.

The measured interval is **physical phrase completion to the first presented
visual acknowledgement of its already-durable marker**. Choose one auditable
timebase:

1. Instrument the existing microphone session's original sample timing and
   calibrated host-clock conversion, durable save completion and actual visible
   presentation on the same monotonic clock. Preserve calibration uncertainty,
   clock discontinuities and the original AAC used to independently locate the
   phrase end. Do not infer an exact phrase end from an entire sentence time.
2. Alternatively use a continuous external audio/video recording that includes
   both the physical utterance and the display. Establish and document the
   recorder's audio/video synchronization error, independently annotate the
   audible phrase end and first display frame, and join the visible marker to
   its durable save receipt. Frame interval plus synchronization uncertainty
   belongs in the result. An uncalibrated phone video is insufficient for a
   tight pass near the threshold.

Do not use approximate wall-clock recording origins, transcript save time,
tool-call duration, polling time or computer-control round trips as substitutes.
Keep durable-save latency separate from visible acknowledgement latency.
Report nearest-rank p95 (`ceil(0.95 × N)`, one-based), sample count, timing
uncertainty, and all failure counts. Require the upper uncertainty bound of the
physical visible p95 to be **at most three seconds**. An unacknowledged utterance
does not disappear from the denominator: treat it as an unbounded latency and
report the failure separately. Delayed recovered markers may pass correctness
while failing quick acknowledgement. Near misses must not create markers.

## Foreground responsiveness

For each matched A/B arm collect at least 40 completed examples of each agreed
action: timeline navigation, interval search, exact screenshot/OCR selection
and speaker-turn selection. Keep the same material and warm/cold policy.
Start at actual native input dispatch and stop at the frame presenting the
requested result or a truthful terminal state. Use an in-app monotonic tracing
boundary or calibrated external high-frame-rate observation. Do not measure
the automation command round trip. Keep cancelled, failed and timed-out
actions visible; do not discard them to improve p95.

Report per-action nearest-rank p95 with uncertainty and trial counts. Enabled
p95 must be no more than **1.10 × matched baseline p95**. Baseline zero or
unresolved timing uncertainty cannot establish a pass. This script does not
manufacture these receipts; add them to the private protocol once measured.

## Offline validation

```sh
python3 -m unittest discover -s scripts/live_context_acceptance -p 'test_*.py' -v
```

Tests use authored counters and private temporary files. They cover PID reuse,
process exits, unreadable counters, sampling gaps, build changes, mixed arms,
cross-boot and overlapping/reordered runs, counter resets and rebounds,
fixed-field fallback parsing, PID/path checks, timeouts and precision disclosure,
shared-service contamination, one-core aggregation and atomic no-overwrite
artifacts. Passing them verifies the tool's logic, not candidate performance.
