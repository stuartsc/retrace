#!/usr/bin/env python3
"""Verify, then explicitly run the private real-product integration package."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import time
import subprocess
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
SNAPSHOT = json.loads((HERE / "source-inputs.json").read_text())
ROOT = Path(SNAPSHOT["productionRoot"])


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify():
    failures = []
    if sha256(Path(__file__).resolve()) != SNAPSHOT["runnerSHA256"]:
        failures.append("private runner changed")
    if ROOT.resolve() != HERE.parent.resolve():
        failures.append("local production dependency moved")
    expected = {entry["path"]: entry["sha256"] for entry in SNAPSHOT["files"]}
    actual_sources = set()
    for folder in SNAPSHOT["productionRoots"]:
        for path in (ROOT / folder).rglob("*"):
            relative = path.relative_to(ROOT)
            if path.is_file() and path.suffix in SNAPSHOT["sourceSuffixes"] and not {"Tests", "TestSupport"}.intersection(relative.parts):
                actual_sources.add(relative.as_posix())
    expected_sources = {name for name in expected if any(name.startswith(folder + "/") for folder in SNAPSHOT["productionRoots"])
                        and not {"Tests", "TestSupport"}.intersection(Path(name).parts)}
    if actual_sources != expected_sources:
        failures.append("production source inventory changed")
    for name, expected_hash in expected.items():
        if not (ROOT / name).is_file() or sha256(ROOT / name) != expected_hash:
            failures.append("production input changed: " + name)
    for name in SNAPSHOT["copiedPaths"]:
        if not (HERE / name).is_file() or sha256(HERE / name) != expected[name]:
            failures.append("copied input changed: " + name)
    if sha256(HERE / "Package.swift") != SNAPSHOT["harnessPackageSHA256"]:
        failures.append("private package manifest changed")
    for base in (ROOT, HERE):
        pins = json.loads((base / "Package.resolved").read_text())["pins"]
        if sorted(pins, key=lambda pin: pin["identity"]) != sorted(SNAPSHOT["dependencyPins"], key=lambda pin: pin["identity"]):
            failures.append("dependency pins changed")
    if failures:
        raise RuntimeError("; ".join(failures))
    return {"productionInputsMatched": len(expected), "exactCopiesMatched": len(SNAPSHOT["copiedPaths"]),
            "actualLocalProducts": SNAPSHOT["products"], "dependencyPinsMatched": True}


class ExecutionInterruption:
    """Latch signals until owned work has stopped and its receipt is written."""
    def __init__(self):
        self.signum = None
        self.previous = {}

    def request(self, signum, _frame):
        if self.signum is None:
            self.signum = signum

    def __enter__(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            self.previous[signum] = signal.signal(signum, self.request)
        return self

    def __exit__(self, *_exception):
        for signum, previous in self.previous.items():
            signal.signal(signum, previous)


def group_members(group):
    result = subprocess.run(["/bin/ps", "-axo", "pid=,pgid=,stat="],
                            capture_output=True, text=True, check=True, timeout=2)
    members = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[1] == str(group):
            members.append({"pid": int(fields[0]), "zombie": fields[2].startswith("Z")})
    return members


def stop_and_join_group(process, grace):
    """Join the direct child and wait for inherited group descendants to stop.

    Orphan zombies belong to the OS reaper, not this process; disclose them
    separately. Never report success while an executing group member remains.
    """
    errors = []
    forced = False
    try:
        initial = group_members(process.pid)
    except (OSError, subprocess.SubprocessError):
        initial = []
        errors.append("initial group inspection failed")
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        process.poll()  # Reap the directly owned leader as soon as it exits.
        try:
            if not any(not item["zombie"] for item in group_members(process.pid)):
                break
        except (OSError, subprocess.SubprocessError):
            break  # Unknown group state still receives the bounded kill below.
        time.sleep(.025)
    try:
        active = any(not item["zombie"] for item in group_members(process.pid))
    except (OSError, subprocess.SubprocessError):
        active = True
        errors.append("pre-kill group inspection failed")
    if active:
        forced = True
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=2)
        reaped = True
    except subprocess.TimeoutExpired:
        reaped = False
        errors.append("leader did not exit after kill")
    remaining = []
    deadline = time.monotonic() + 2
    while True:
        try:
            remaining = group_members(process.pid)
        except (OSError, subprocess.SubprocessError):
            errors.append("final group inspection failed")
            break
        if not any(not item["zombie"] for item in remaining) or time.monotonic() >= deadline:
            break
        time.sleep(.025)
    active_pids = [item["pid"] for item in remaining if not item["zombie"]]
    return {"leaderReaped": reaped, "groupDrained": reaped and not active_pids and not errors,
            "forcedKill": forced, "observedGroupPIDs": [item["pid"] for item in initial],
            "remainingActivePIDs": active_pids,
            "remainingZombiePIDs": [item["pid"] for item in remaining if item["zombie"]],
            "cleanupErrors": errors}


def execute_owned(command, cwd, env, output, interruption, grace):
    process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                               stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    started = time.monotonic()
    try:
        while interruption.signum is None:
            try:
                process.wait(timeout=.05)
                break
            except subprocess.TimeoutExpired:
                continue
    finally:
        cleanup = stop_and_join_group(process, grace)
    return {"argv": command, "exitCode": process.returncode,
            "interruptedSignal": interruption.signum, "elapsedSeconds": time.monotonic() - started,
            **cleanup}


def execute_commands(commands, cwd, env, log_path, receipt_path, metadata=None, postcheck=None, grace=2):
    receipts = []
    error = None
    after = None
    with ExecutionInterruption() as interruption:
        # Exclusive creation preserves prior failures. The signal latch remains
        # installed through child cleanup, post-check and receipt publication.
        with log_path.open("x") as output:
            try:
                for command in commands:
                    if interruption.signum is not None:
                        break
                    receipt = execute_owned(command, cwd, env, output, interruption, grace)
                    receipts.append(receipt)
                    if receipt["exitCode"] != 0 or not receipt["groupDrained"] or interruption.signum is not None:
                        break
            except Exception as failure:
                error = type(failure).__name__ + ": " + str(failure)
        try:
            if postcheck is not None:
                after = postcheck()
        except Exception as failure:
            error = type(failure).__name__ + ": " + str(failure)
        report = dict(metadata or {})
        report.update(commands=receipts, interruptedSignal=interruption.signum, error=error, after=after,
                      completed=interruption.signum is None and error is None and len(receipts) == len(commands)
                      and all(item["exitCode"] == 0 and item["groupDrained"] for item in receipts),
                      log=str(log_path), logSHA256=sha256(log_path))
        with receipt_path.open("x") as target:
            json.dump(report, target, indent=2)
            target.write("\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("verify", "run"))
    parser.add_argument("--log", type=Path)
    args = parser.parse_args()
    before = verify()
    if args.mode == "verify":
        print(json.dumps({"verified": before, "compilationAttempted": False}, sort_keys=True))
        return 0
    if shutil.disk_usage(ROOT).free < 20 * 1024**3:
        raise RuntimeError("Less than 20 GiB free; preserve recording headroom")
    env = runpy.run_path(str(ROOT / "scripts/validate_noninteractive.py"))["validation_environment"](os.environ)
    when = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    log_path = args.log or Path("/tmp") / ("retrace-audio-integration-" + when + ".log")
    common = ["/usr/bin/nice", "-n", "15", "/usr/bin/swift"]
    location = ["--package-path", str(HERE), "--scratch-path", str(HERE / ".build")]
    commands = [common + ["package"] + location + ["clean"],
                common + ["test"] + location + ["--jobs", "2"]]
    receipt = execute_commands(commands, HERE, env, log_path, HERE / ("validation-" + when + ".json"),
        metadata={"productionSourceCommit": SNAPSHOT["productionCommit"], "before": before,
                  "compilationAttempted": True, "actualNativeModelInference": False,
                  "wholeAppOptimizedBuild": "still required"}, postcheck=verify)
    print(json.dumps(receipt, sort_keys=True))
    if receipt["interruptedSignal"] is not None:
        return 128 + receipt["interruptedSignal"]
    return 0 if receipt["completed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
