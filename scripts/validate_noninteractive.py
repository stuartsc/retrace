#!/usr/bin/env python3
"""Run isolated, low-concurrency validation without interactive opt-ins."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


def validation_environment(source):
    # Native/visible/focus/input tests and benchmark exports require their own
    # scheduled session. Never inherit those switches from an agent shell.
    result = {key: value for key, value in source.items()
              if not key.startswith(("RETRACE_", "RUN_INTERACTIVE_"))
              and key not in {"AX_VERBOSE", "TEST_SCREENSHOT_PATH"}}
    result["RETRACE_TEST_DISABLE_FILE_LOGGING"] = "1"
    result["RETRACE_TEST_NONINTERACTIVE"] = "1"
    result.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("debug", "release"))
    parser.add_argument("--filter", help="Swift test filter (debug only)")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--native-draft", action="store_true",
                        help="Silent authored PCM replay using installed speech assets")
    args = parser.parse_args()
    if args.mode == "release" and (args.filter or args.skip_build or args.native_draft):
        parser.error("release builds do not accept test-only arguments")
    root = Path(__file__).resolve().parent.parent
    if shutil.disk_usage(root).free < 20 * 1024**3:
        parser.error("Less than 20 GiB free; preserve recording headroom")
    command = ["/usr/bin/nice", "-n", "15", "/usr/bin/swift"]
    command += ["test"] if args.mode == "debug" else ["build", "-c", "release"]
    command += ["--jobs", "2", "--scratch-path",
                str(root / ".build-validation" / args.mode)]
    if args.filter:
        command += ["--filter", args.filter]
    if args.skip_build:
        command += ["--skip-build"]
    environment = validation_environment(os.environ)
    if args.native_draft:
        if args.filter:
            parser.error("--native-draft selects its own isolated test filter")
        command += ["--filter", "LiveTranscriptionNativeTests"]
        environment["RETRACE_LIVE_DRAFT_NATIVE_TEST"] = "1"
    return subprocess.call(command, cwd=root, env=environment)


if __name__ == "__main__":
    sys.exit(main())
