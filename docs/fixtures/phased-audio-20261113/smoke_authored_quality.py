"""Read-only authored-fixture smoke; emits content-free metadata only."""

import hashlib
import json
import os
from pathlib import Path
import re
import resource
import time
import wave
import sys

ROOT = Path(__file__).resolve().parents[3]
RECEIPT = ROOT / "docs/fixtures/phased-audio-20261113/quality-backend-smoke.json"
FIXTURE = ROOT / "Processing/Tests/Fixtures/WhisperTimedWords/authored.wav"
REFERENCE = FIXTURE.with_name("reference.txt")
sys.path.insert(0, str(ROOT / "scripts"))
for key, value in {
    "HF_HUB_OFFLINE": "1",
    "TRANSFORMERS_OFFLINE": "1",
    "HF_HUB_DISABLE_TELEMETRY": "1",
    "PYANNOTE_METRICS_ENABLED": "0",
    "TOKENIZERS_PARALLELISM": "false",
}.items():
    os.environ[key] = value
# Native output may contain decoded words or enrollment diagnostics. This smoke
# intentionally retains only the count/timing/oracle receipt below.
quiet = os.open(os.devnull, os.O_WRONLY)
os.dup2(quiet, 1)
os.dup2(quiet, 2)
os.close(quiet)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def words(value):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", value.lower())


def word_error_rate(expected, actual):
    prior = list(range(len(actual) + 1))
    for index, left in enumerate(expected, 1):
        current = [index]
        for position, right in enumerate(actual, 1):
            current.append(
                min(
                    current[-1] + 1,
                    prior[position] + 1,
                    prior[position - 1] + (left != right),
                )
            )
        prior = current
    return prior[-1] / max(1, len(expected))


started = time.monotonic()
receipt = {
    "smokeScriptSHA256": digest(Path(__file__)),
    "fixtureSHA256": digest(FIXTURE),
    "referenceSHA256": digest(REFERENCE),
    "scope": "authored audio only; local pinned runtime; no live inference or voice writes",
    "localGoverned": True,
    "threads": 1,
    "nice": os.getpriority(os.PRIO_PROCESS, 0),
    "installed": False,
    "stage": "preflight",
    "outcome": "blocked",
}
exit_code = 2
try:
    from audio_worker.outlook_backend import OutlookBackend
    from audio_worker.contract import JobError
    from retrace_companion.repair import needs_repair, accept_repair

    with wave.open(str(FIXTURE)) as reader:
        duration = reader.getnframes() / reader.getframerate()
    receipt["audioSeconds"] = duration
    backend = OutlookBackend(
        Path("/Users/stuartbond/outlook"), local_governed=True, threads=1
    )
    receipt["stage"] = "quality"
    initial = backend.transcribe(FIXTURE, duration)
    score = backend.last_average_logprob
    chosen = initial
    repair_required = needs_repair(initial, score)
    receipt["repairRequired"] = repair_required
    receipt["repairAccepted"] = False
    if repair_required:
        receipt["stage"] = "repair"
        candidate, candidate_score = backend.repair(FIXTURE, duration, initial)
        accepted = accept_repair(initial, candidate, score, candidate_score)
        receipt["repairAccepted"] = accepted
        if accepted:
            chosen = candidate
    if not chosen["text"].strip() or not chosen["words"] or not chosen["turns"]:
        raise JobError("authored_audio_output_incomplete")
    receipt.update(
        {
            "outcome": "passed",
            "stage": "complete",
            "textWordCount": len(words(chosen["text"])),
            "timedWordCount": len(chosen["words"]),
            "speakerTurnCount": len(chosen["turns"]),
            "unplacedWords": chosen["unplacedWords"],
            "voiceReferenceCount": chosen["voiceReferenceCount"],
            "wordErrorRate": word_error_rate(
                words(REFERENCE.read_text()), words(chosen["text"])
            ),
            "processingSeconds": chosen["processingSeconds"],
            "modelPinsSHA256": digest(ROOT / "scripts/audio_worker/runtime-pins.json"),
        }
    )
    exit_code = 0
except Exception as error:
    from audio_worker.contract import JobError

    receipt["errorType"] = type(error).__name__
    receipt["category"] = (
        str(error)
        if isinstance(error, JobError)
        else "runtime_initialisation_or_inference_failed"
    )
    if type(error).__name__ == "PackageNotFoundError":
        receipt["category"] = "required_runtime_package_missing"
        receipt["package"] = getattr(error, "name", None)
    if isinstance(error, FileNotFoundError):
        receipt["category"] = "required_runtime_artifact_missing"
        receipt["artifactName"] = Path(error.filename).name if error.filename else None
    if str(error) == "runtime_version_changed":
        import importlib.metadata

        pins = json.loads((ROOT / "scripts/audio_worker/runtime-pins.json").read_text())
        receipt["packageMismatches"] = {
            name: {"expected": expected, "installed": importlib.metadata.version(name)}
            for name, expected in pins["packages"].items()
            if importlib.metadata.version(name) != expected
        }
finally:
    receipt["elapsedSeconds"] = time.monotonic() - started
    receipt["peakProcessRSSBytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    RECEIPT.parent.mkdir(parents=True, exist_ok=True)
    RECEIPT.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
raise SystemExit(exit_code)
