"""One App-governed local job; no listener, daemon or history scan.

The native owner must hold refinement admission and terminate/join this process
on cancellation. --remote retains the ordinary primary-host preflight.
"""

import argparse
from contextlib import contextmanager, nullcontext
import fcntl
import hashlib
import os
from pathlib import Path
import select
import subprocess
import sys

from .contract import MAX_JOB, decode, digest, encode, validate_job
from .queue import publish_file, read_private
from .worker import Processor


@contextmanager
def remote_monitor(root: Path, job: str):
    """Own the independent watchdog until inference and result publication finish."""
    native_lock = os.open(
        root / ("." + job + ".native.lock"),
        os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
        0o600,
    )
    monitor = None
    read_fd = write_fd = None
    try:
        fcntl.flock(native_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        read_fd, write_fd = os.pipe()
        monitor = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "retrace_companion.lease_watchdog",
                "--database",
                str(root / "delivery.sqlite"),
                "--job",
                job,
                "--owner",
                str(os.getpid()),
                "--ready",
                str(write_fd),
            ],
            pass_fds=(write_fd,),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        os.close(write_fd)
        write_fd = None
        if not select.select([read_fd], [], [], 3)[0] or os.read(read_fd, 1) != b"1":
            raise RuntimeError("lease_monitor_unavailable")
        os.close(read_fd)
        read_fd = None
        yield monitor
    finally:
        # Abrupt owner exit leaves this independent process alive to kill the
        # entire inference group. Orderly return joins it before releasing the
        # per-job lock; the outer supervisor then drains the inference group.
        if monitor is not None:
            monitor.terminate()
            try:
                monitor.wait(timeout=1)
            except subprocess.TimeoutExpired:
                monitor.kill()
                monitor.wait()
        for descriptor in (read_fd, write_fd):
            if descriptor is not None:
                os.close(descriptor)
        os.close(native_lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--outlook", type=Path, required=True)
    parser.add_argument("--threads", type=int, choices=range(1, 5), default=1)
    parser.add_argument("--remote", action="store_true")
    args = parser.parse_args()
    if not args.remote:
        os.setsid()
    digest(args.job)
    with remote_monitor(args.root, args.job) if args.remote else nullcontext():
        # Only a pre-published request in the private receiver layout is accepted.
        data = read_private(
            args.root / "request-archive" / (args.job + ".json"), MAX_JOB
        )
        if hashlib.sha256(data).hexdigest() != args.job:
            raise ValueError("request_digest")
        job = decode(data, MAX_JOB)
        validate_job(job)
        if job["kind"] != "speaker":
            raise ValueError("local_audio_only")
        result = Processor(
            args.root,
            args.outlook,
            local_governed=not args.remote,
            threads=args.threads,
        ).process(args.job, job)
        destination = args.root / "execution-results"
        destination.mkdir(mode=0o700, exist_ok=True)
        publish_file(destination / (args.job + ".json"), encode(result))


if __name__ == "__main__":
    main()
