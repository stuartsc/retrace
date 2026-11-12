"""Process one explicitly supplied immutable job; never scans recording history."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import resource
import tempfile
import time
from pathlib import Path

from .contract import (
    JobError,
    decode_window,
    initialize_directory,
    load_job,
    load_result,
    publish_result,
    validate_result,
)
from .outlook_backend import OutlookBackend
from .speakers import align_words


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--outlook", type=Path, default=Path.home() / "outlook")
    args = parser.parse_args()
    job = load_job(args.request)
    initialize_directory(args.results)
    lock = os.open(
        args.results / ".worker.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600
    )
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise JobError("worker_busy") from error
        destination = args.results / (job.identifier + ".json")
        if os.path.lexists(destination):
            load_result(destination, job)
            print(json.dumps({"jobID": job.identifier, "status": "already_published"}))
            return 0
        started = time.monotonic()
        with tempfile.TemporaryDirectory(prefix="retrace-worker-") as temporary:
            wav = Path(temporary) / "window.wav"
            decode_window(job, args.media, wav)
            backend = OutlookBackend(args.outlook)
            prepared = backend.transcribe(wav, job.sample_count / 16_000)
            segments = align_words(
                prepared.pop("words"), prepared.pop("turns"), job_id=job.identifier
            )
            result = {
                "jobID": job.identifier,
                "storeID": job.store_id,
                "source": job.source,
                "status": "complete",
                "startMilliseconds": job.start_ms,
                "endMilliseconds": job.end_ms,
                "sampleCount": job.sample_count,
                "segments": segments,
                "models": backend.pins,
                "automaticNamesCalibrated": False,
                "totalSeconds": time.monotonic() - started,
                "processPeakResidentBytes": resource.getrusage(
                    resource.RUSAGE_SELF
                ).ru_maxrss,
                **prepared,
                **job.result_identity,
            }
            validate_result(result, job)
            publish_result(args.results, job.identifier, result)
        print(
            json.dumps(
                {
                    "jobID": job.identifier,
                    "status": "published",
                    "segments": len(segments),
                    "seconds": result["totalSeconds"],
                }
            )
        )
        return 0
    finally:
        os.close(lock)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except JobError as error:
        print(json.dumps({"status": "pending", "reason": str(error)}))
        raise SystemExit(2) from None
