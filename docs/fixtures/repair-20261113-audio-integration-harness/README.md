# Real-product audio integration harness

This tracked recipe recreates the ignored `.audio-integration-validation` package
from the production checkout. It depends on the actual local App, Processing,
Storage, Shared and Database products. Production `Package.swift` is unchanged;
only exact XCTest files and authored fixtures are copied.

From the production repository root:

```sh
python3 docs/fixtures/repair-20261113-audio-integration-harness/prepare.py
python3 .audio-integration-validation/run.py verify
```

Preparation checks every pinned source first, recreates the ignored resolved pins
only if missing, copies tests/fixtures byte for byte, and substitutes only the
current checkout path in the private manifest. It refuses to overwrite a package
that already has build state. Changed production inputs require a deliberately
updated manifest and new validation, not bypassing the checks.

Only with the shared Swift build slot available:

```sh
python3 .audio-integration-validation/run.py run --log /tmp/retrace-audio-integration-focused.log
```

The runner uses a clean private build, nice 15, two jobs, the reviewed noninteractive
environment and pre/post input hashes. It never enables native-model or UI opt-ins.
Each command owns a new POSIX process group. SIGINT/SIGTERM are latched through
cleanup and receipt writing; inherited descendants receive TERM, then KILL after
a bounded grace. The leader is reaped, running group members must drain, and any
OS-owned orphan zombies are disclosed separately. Failure or interruption blocks
subsequent commands. Original signal handlers are restored afterwards. Logs and
receipts use exclusive creation to preserve earlier failures.

Run the authored process lifecycle checks without Swift, devices or app access:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s docs/fixtures/repair-20261113-audio-integration-harness -p test_run.py -v
```

A refusal by SwiftPM to consume a local product with the production unsafe linker
flags must be retained as a limitation. Use the ordinary safe runner in that case;
never substitute copied App/Storage implementations. A separate clean optimised
build of the full production app remains required after focused integration tests.

## Clean whole-app release

The focused run passed 15 tests, zero skips and zero failures. Its original
command/cleanup receipt, result summary and compressed log are retained here.
The production modules were real local dependency products; no UI test target
or substitute implementation was used.

After focused validation and with the sole Swift build slot available:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 docs/fixtures/repair-20261113-audio-integration-harness/release.py
```

The release recipe verifies the harness, inventories all files in every
production module (including UI/assets, native headers/libraries and source
utilities) plus Package.swift/resolved, release scripts and this recipe.
UI/Info.plist and UI/Retrace.entitlements are included even though SwiftPM
excludes those packaging inputs. It freezes file sizes, SHA256 and symlink
targets before cleaning, builds through the reviewed low-priority two-job
runner inside an owned process group, and requires the identical full inventory
afterwards. The output executable hash and size, command duration and compressed
log accompany the receipt. Neither release compilation nor the controlled
native-output tests establish actual speech-model or installed acceptance.

The first release attempt was deliberately interrupted after 106.5 seconds
to expand the earlier harness-only precheck to this full input inventory.
Its interrupted receipt and log are preserved. It reported no compiler error
and its owned process group drained; it is not a passed release.


The clean optimised whole-app build passed in 3,736.19 seconds. See
`release-result.json`, the exact `release-validation-*.json` receipt and
`release-inputs-*.json` full inventory. All 751 full inputs, 348 focused inputs,
seven exact copied files and dependency pins matched before/after. The lengthy
compile and unsuccessful guarded sample attempt are recorded separately in
`compiler-diagnostic.json`; they do not constitute app performance measurements.
Neither native-model nor installed acceptance is claimed.
