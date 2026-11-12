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
- Noninteractive runner unit tests and `git diff --check` passed. The clean
  focused actual-product integration passed 15 tests, zero skips and zero
  failures on source checkpoint `b495d4a`: five AAC compactor tests, two writer
  policy tests and eight native persistence tests. Compilation took 314.73
  seconds and the tests took 3.453 seconds. The separate clean optimised
  whole-app build also passed in 3,736.19 seconds (62m16s), with all 751 full inputs and the 348 focused inputs
  unchanged. No installed acceptance is claimed.
- Native assets are still reported missing; actual speech quality/continuous
  coverage/latency/energy acceptance remains open. Fast native preview and
  governed durable-text latency remain separate gates. No model downloads ran.

Suggested focused filter after the source freeze:

```
AudioWriterPolicyTests|AACContainerCompactorTests|NativeFirstPassPersistenceTests|NativeFirstPassCoverageTests|AudioProcessingFreshnessTests|AudioProcessingGovernorTests|PersistedAudioBatchCallbackTests|ExactAudioDecoderTests|MarkerAudioMediaTests|TranscriptAudioPlaybackTests
```


## Focused real-product harness (clean validation passed)

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
unchanged. SwiftPM accepted the real local product dependency, compiled the
production modules and passed all three focused test suites. Input hashes, exact
copies and pins matched before and after; both owned command groups drained.

The validated command is:

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

SwiftPM accepted the production package's existing linker settings without a
substitute module or manifest change. A separate clean optimised build of the
full production application has now passed. The earlier native full suite
and AAC component suite remain separate receipts, not this harness's results.
The exact command/cleanup receipt, compressed log, source manifest and result
summary are retained in `docs/fixtures/repair-20261113-audio-integration-harness`.


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
released the build slot for clean focused integration, which passed, followed
by the mandatory clean optimised whole-app build. That build passed through the
reviewed noninteractive runner inside the same owned process-group wrapper; both command groups drained without forced killing.


### Clean release input coverage

The first release attempt was deliberately interrupted after 106.5 seconds to
replace its harness-only hash precheck with a full whole-app input freeze. Its
interrupted receipt and log remain retained; no compiler failure occurred and
its process group drained. The restarted recipe snapshots 751 files across every
production module, including UI/resources, native binaries/headers, source
utilities, Package.swift/resolved, Info.plist/entitlements and release scripts.
It requires identical file inventory, bytes, hashes and symlink targets after
the separate clean optimised build, and records the resulting executable hash.
The low-priority two-job build passed in 3,736.19 seconds; the final receipt
matched all 751 full inputs, all 348 focused inputs, seven copied fixtures/tests
and dependency pins. The compiled executable is 62,443,944 bytes, SHA256
`2f606db9d0cca8f5de6ff3302581d62f050c434948a22a290a07b7093dd13e38`.
The complete receipt, input manifest, compressed log and build environment are
retained beside the focused-test receipts.


### Compiler delay and acceptance boundary

The long release elapsed time is a build observation, not an application
performance result. Earlier owned compiler snapshots showed scheduler starvation;
the final frontend later accumulated 10m09.50s CPU over 10m54s elapsed at nice 15,
using about 2.67 GiB RSS. A requested read-only sample was cancelled by the identity
guard because that compiler had already exited. The application then linked
successfully. No stack sample exists to identify a repeated optimiser/typechecker
hotspot, so the exact reason for that final CPU-heavy compile remains unproven.
The diagnostic receipt records this distinction.

The native speech defaults remain off. The root reported en-AU assets unavailable;
this agent neither rechecked nor downloaded them. Controlled native outputs in
the eight persistence tests establish durable integration, not real recognition
quality, continuous framework coverage, latency or energy acceptance. This branch
has 15 focused integration tests and a clean whole-app release receipt; the earlier
1,733-test native full suite remains separate. No app was installed, no live
preferences or history changed, and no model/device/UI opt-in ran. Packaging and
installed acceptance belong to the root's subsequent stage.
