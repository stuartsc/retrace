# New-audio storage integration — 13 November 2026

## State

Isolated worktree `/Users/stuartbond/backintime-audio-delivery-20261113`, branch
`repair/audio-delivery-20261113`, based on native checkpoint `df0176c`. The V23
compactor commit `08ebb78` was cherry-picked as `7d3466a`. The two noninteractive
runner files are inherited exactly from reviewed checkpoint `7b0ac80`.

This is source integration, not installation or acceptance. No live preferences,
recordings, models or app bundles were changed. No device or UI operation ran.
Root owns build scheduling and the one bounded integration-policy review; the
compactor and native-first-pass implementations already have their own reviews.

## One policy for every writer

`AudioWriterPolicy.production()` reads
`audioContainerPaddingCompactionDisabled` from the application's own preferences
once, when `ServiceContainer` is constructed. Absent/false enables compaction for
new production AAC. True disables it for all writers owned by the next container;
restart is the supported rollback boundary. Existing writers retain their choice
so a mid-session preference change cannot leave different paths with different
settings.

The five construction paths use that same immutable policy:

| Path | Choice |
| --- | --- |
| Production initialization | Production snapshot |
| Private in-memory/test initialization | Explicitly off |
| Service initialization and initial backfill | Owning container's snapshot |
| Pass-two/pass-three refinement installation | Owning container's snapshot |
| Model-upgrade backfill installation | Owning container's snapshot |

`AudioSegmentWriter` itself still defaults the option off for other consumers.
There is one rollback preference, no extra per-writer defaults and no runtime
settings writes. The separate `liveMicrophoneDraftTrialEnabled` and
`nativeFirstPassReuseTrialEnabled` gates remain default off and are unchanged.

## Preservation and native handoff

The compactor runs only after a newly encoded AAC has closed and before its final
path/size returns to Processing. It changes container padding/offsets, not AAC
packets, codec settings, gapless metadata or source sample timing. Unknown profiles
retain ordinary output. The existing component tests verify packets/cookie,
priming/remainder, decoded samples and seeking with real native codecs.

Processing therefore records the final file size and hashes the final compacted
file for native-first-pass proof. No proof is generated from the pre-compaction
container. A new integration regression checks the compacted digest, exact decoded
frame count, SQLite size and searchable retained native text without fresh CPU
inference. CPU correction and fallback remain independent.

Only new output is eligible. No directory scan, historical rewrite, deletion,
retention change, bulk recompression or new codec is introduced. Original files
remain readable by the existing decoder, and rollback leaves already compacted
files unchanged and readable.

## Validation and pending acceptance

- Inherited native component receipt: 5 tests, 0 skips, 0 failures; authored
  10/15/21.248-second examples saved approximately 39.7%/30.6%/23.9%. Those are
  authored measurements, not a prediction of whole-library savings.
- The root reports the separate native branch full suite passed 1,733 tests,
  24 explicit skips, zero failures in 568.024 seconds. This does not validate the
  additional integration changes in this branch.
- New `AudioWriterPolicyTests` exercises private preference defaults, captured
  rollback behaviour, private-test policy and real AAC writer output. It also
  checks creating a rollback writer leaves previous bytes unchanged.
- `NativeFirstPassPersistenceTests.testNativeProofBindsCompactedAACBeforeSearchablePublication`
  exercises native encoding/decoding and private SQLite with controlled native
  recognition output. It does not require or simulate actual Apple inference.
- Noninteractive runner unit tests and `git diff --check` passed. Swift build and
  tests have not run on this source integration; retention owns the next build
  slot. Freeze/commit source before focused validation, then run the separate
  clean optimised build and the appropriate full suite under the root's schedule.
- Native assets are still reported missing; actual speech quality/continuous
  coverage/latency/energy acceptance remains open. Fast native preview and
  governed durable-text latency remain separate gates. No model downloads ran.

Suggested focused filter after the source freeze:

```
AudioWriterPolicyTests|AACContainerCompactorTests|NativeFirstPassPersistenceTests|NativeFirstPassCoverageTests|AudioProcessingFreshnessTests|AudioProcessingGovernorTests|PersistedAudioBatchCallbackTests|ExactAudioDecoderTests|MarkerAudioMediaTests|TranscriptAudioPlaybackTests
```


## Focused real-product harness (prepared; not compiled)

The bounded policy integration review passed with no findings. A private package
is prepared at `.audio-integration-validation`, ignored with its build products.
Its manifest declares only three test targets and a local path dependency on the
unchanged production package. It imports the actual App, Processing, Storage,
Shared and Database products; it does not declare replacement production targets
or copy production implementation into the harness.

Exact copies of the three selected XCTest files keep their `App/Tests`,
`Processing/Tests` and `Storage/Tests` paths. Mirrored authored WAV/provenance/oracle
and AAC fixtures preserve their existing `#filePath` lookups without editing any
test source. The harness snapshots 348 production/test/fixture inputs, verifies
seven exact copied inputs, preserves the three resolved dependency pins, and
checks its own manifest and runner hashes. The production `Package.swift` is
unchanged. Preparation verification and Python syntax checking passed; no Swift
manifest evaluation, compilation or test execution has occurred in this harness.

After the root releases the build slot, the explicit command is:

```sh
python3 .audio-integration-validation/run.py run --log /tmp/retrace-audio-integration-focused.log
```

The runner verifies source/copy/pin hashes, checks 20 GiB free headroom, cleans its
private scratch directory and invokes the real SwiftPM products at nice 15 with
two jobs. It inherits the reviewed noninteractive environment isolation, disables
live file logging, and enables no model, device or UI test opt-ins. The log is
created exclusively so prior failures cannot be overwritten. A second hash/pin
check and a JSON exit-code/log-hash receipt follow execution. `verify` performs
only the source/copy checks, without invoking Swift.

Local-product unsafe flags have not yet been evaluated by SwiftPM. If the package
manager rejects the real production dependency, retain that failure and use the
ordinary safe runner; do not bypass the restriction using substitute App/Storage
targets. Regardless of focused-test success, a separate clean optimised build of
the full production application remains mandatory. The earlier native full suite
and AAC component suite remain separate receipts, not this harness's results.


### Harness process ownership correction

The one Python advisory review found that `subprocess.call` could leave build
children running after interruption and omit an interrupted receipt. The runner
now owns each command's new process group, latches SIGINT/SIGTERM, sends TERM with
a bounded grace then KILL, reaps the direct child and waits for executing inherited
group members to stop. OS-owned orphan zombies are disclosed separately. Cleanup
and receipt writing finish before restoring signal handlers, and interruption
prevents the next stage. Three real private process tests passed, including both
signals against an authored child/grandchild that ignore TERM. No Swift or app
operation occurred during those checks.

The reproducible package manifest, runner, preparation script, pinned source
manifest, resolved dependency pins, lifecycle tests and their receipt are tracked
under `docs/fixtures/repair-20261113-audio-integration-harness`. Preparation changes
only the checkout path in the ignored private copy and rechecks all input hashes.
The refreshed runner hash and all 348 inputs/seven copied files verify. The root
has now released the build slot for clean focused integration followed by the
mandatory clean optimised whole-app build; those results are still pending.
