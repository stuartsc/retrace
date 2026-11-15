"""Single owned inference process. Reuses immutable audio results and local-only models."""

from __future__ import annotations

import fcntl
import hashlib
import os
import resource
import tempfile
import time
from pathlib import Path

from audio_worker.contract import (
    Job,
    decode_window,
    load_result,
    publish_result,
    validate_result as validate_audio_result,
)
from audio_worker.outlook_backend import OutlookBackend
from audio_worker.speakers import align_words

from .contract import (
    CompanionError,
    MAX_RESULT,
    decode,
    encode,
    validate_job,
    validate_result,
)
from .context import LocalRanker, propose_context
from .queue import CompanionQueue, publish_file, read_private


def audio_request(job):
    """Civil-clock placement stays approximate; UUID continuity/sample identity remains exact."""
    source = job["speaker"]
    identity = source["sourceIdentity"]
    start_ms = int(
        identity["approximateOrigin"] + identity["startSample"] * 1000 // 16000
    )
    consumed = 0
    media = []
    for item in source["media"]:
        media.append(
            {
                key: item[key]
                for key in (
                    "sha256",
                    "byteCount",
                    "offsetSamples",
                    "countSamples",
                    "mediaID",
                )
            }
            | {"startMilliseconds": start_ms + consumed * 1000 // 16000}
        )
        consumed += item["countSamples"]
    return {
        "version": 2,
        "storeID": job["sourceStoreID"],
        "source": "microphone",
        "recordingGeneration": identity["recordingGeneration"],
        "continuityID": identity["continuityID"],
        "startSample": identity["startSample"],
        "startMilliseconds": start_ms,
        "media": media,
    }


class Processor:
    def __init__(self, root, outlook, *, local_governed=False, threads=2):
        self.root = root
        self.outlook = outlook
        self.ranker = LocalRanker()
        self.audio = None
        self.local_governed = local_governed
        self.threads = threads

    def process(self, job_id, job):
        validate_job(job)
        destination = self.root / "results" / (job_id + ".json")
        if destination.exists():
            result = decode(read_private(destination, MAX_RESULT), MAX_RESULT)
            validate_result(result, job, job_id)
            return result
        result = {
            "version": 1,
            "jobID": job_id,
            "kind": job["kind"],
            "sourceStoreID": job["sourceStoreID"],
        }
        if job["kind"] == "context":
            result["contextProposal"] = propose_context(job, job_id, rank=self.ranker)
        else:
            result["speakerEnrichment"] = self.speaker(job)
        validate_result(result, job, job_id)
        return result

    def speaker(self, job):
        request = audio_request(job)
        data = encode(request)
        audio_id = hashlib.sha256(data).hexdigest()
        publish_file(self.root / "audio-jobs" / (audio_id + ".job.json"), data)
        parsed = Job.parse(request, audio_id)
        recipe = hashlib.sha256(
            encode(
                {
                    "stage": job.get("processingStage", "quality"),
                    "recipe": "mlx-large-v3-pyannote-selective-normalised-v1",
                    "pins": Path(__file__)
                    .parents[1]
                    .joinpath("audio_worker/runtime-pins.json")
                    .read_text(),
                }
            )
        ).hexdigest()
        cache = self.root / "audio-results" / recipe
        cache.mkdir(mode=0o700, exist_ok=True)
        destination = cache / (audio_id + ".json")
        if destination.exists():
            result = load_result(destination, parsed)
        else:
            started = time.monotonic()
            with tempfile.TemporaryDirectory(prefix="retrace-companion-") as directory:
                wav = Path(directory) / "window.wav"
                decode_window(parsed, self.root / "objects", wav)
                if self.audio is None:
                    self.audio = OutlookBackend(
                        self.outlook,
                        local_governed=self.local_governed,
                        threads=self.threads,
                    )
                prepared = self.audio.transcribe(wav, parsed.sample_count / 16000)
                from .repair import needs_repair, accept_repair

                score = getattr(self.audio, "last_average_logprob", None)
                # Keep the second-pass candidate even if the selective retry fails.
                if needs_repair(prepared, score):
                    quality = dict(prepared)
                    try:
                        repaired, repaired_score = self.audio.repair(
                            wav, parsed.sample_count / 16000, quality
                        )
                        repair_key = hashlib.sha256(
                            encode(
                                {
                                    "stage": "repair",
                                    "recipe": "normalised-pcm-v1",
                                    "audio": audio_id,
                                    "qualityRecipe": recipe,
                                }
                            )
                        ).hexdigest()
                        publish_file(
                            self.root / "audio-jobs" / (repair_key + ".candidate.json"),
                            encode({"original": quality, "candidate": repaired}),
                        )
                        if accept_repair(quality, repaired, score, repaired_score):
                            prepared = repaired
                    except Exception:
                        prepared = quality
                turns = align_words(
                    prepared.pop("words"), prepared.pop("turns"), job_id=audio_id
                )
                result = {
                    "jobID": audio_id,
                    "storeID": parsed.store_id,
                    "source": parsed.source,
                    "status": "complete",
                    "startMilliseconds": parsed.start_ms,
                    "endMilliseconds": parsed.end_ms,
                    "sampleCount": parsed.sample_count,
                    "segments": turns,
                    "models": self.audio.pins,
                    "automaticNamesCalibrated": False,
                    "totalSeconds": time.monotonic() - started,
                    "processPeakResidentBytes": resource.getrusage(
                        resource.RUSAGE_SELF
                    ).ru_maxrss,
                    **prepared,
                    **parsed.result_identity,
                }
                validate_audio_result(result, parsed)
                publish_result(cache, audio_id, result)
        return {
            "sourceIdentity": job["speaker"]["sourceIdentity"],
            "firstPassSHA256": hashlib.sha256(
                job["speaker"]["firstPassText"].encode()
            ).hexdigest(),
            "enhancedText": result["text"],
            "turns": result["segments"],
            "automaticNamesCalibrated": False,
            "modelFingerprint": hashlib.sha256(encode(result["models"])).hexdigest(),
        }


def run_worker(root, outlook, once=False):
    queue = CompanionQueue(root)
    descriptor = os.open(
        root / ".inference.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600
    )
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise CompanionError("worker_already_running") from error
        queue.recover_interrupted()
        processor = Processor(root, outlook)
        while True:
            from .execution import heartbeat

            heartbeat(queue.db)
            work = queue.claim()
            if work:
                try:
                    if work["request"]["kind"] == "speaker":
                        from .execution import supervised

                        publish_file(
                            root / "request-archive" / (work["jobID"] + ".json"),
                            encode(work["request"]),
                        )
                        result = supervised(queue, work, outlook)
                    else:
                        result = processor.process(work["jobID"], work["request"])
                    queue.complete(work["jobID"], encode(result))
                except Exception as error:
                    # Never expose paths, model diagnostics or captured text through status.
                    reason = (
                        str(error)
                        if isinstance(error, CompanionError)
                        else type(error).__name__
                    )
                    queue.fail(work["jobID"], reason)
            if once:
                return
            if not work:
                time.sleep(1)
    finally:
        os.close(descriptor)
        queue.close()
