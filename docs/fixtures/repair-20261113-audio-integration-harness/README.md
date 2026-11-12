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
