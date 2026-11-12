"""Pinned, offline MLX/pyannote adapter on the primary Mac only.

Reuses Outlook's enrollment matching and WAV/tensor decoder. It does not write
Outlook or Retrace databases. Names are suggestions until explicitly confirmed;
the existing cosine thresholds are not a 98% precision calibration.
"""

from __future__ import annotations

import hashlib
import importlib.metadata
import inspect
import json
import math
import os
import sys
import time
from numbers import Real
from pathlib import Path
from typing import Any

from .contract import JobError
from .runtime import configure_torch_runtime


def _hash(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as reader:
        while block := reader.read(1024 * 1024):
            value.update(block)
    return value.hexdigest()


def preflight(outlook: Path, cache: Path | None = None) -> dict[str, Any]:
    role = outlook / "logs/autosync/_role.json"
    if (
        role.stat().st_size > 4096
        or json.loads(role.read_text()).get("role") != "primary"
    ):
        raise JobError("not_primary_host")
    pins = json.loads(Path(__file__).with_name("runtime-pins.json").read_text())
    for package, version in pins["packages"].items():
        if importlib.metadata.version(package) != version:
            raise JobError("runtime_version_changed")
    for name, expected in pins["outlook"].items():
        if _hash(outlook / "src/intelligence/audio" / name) != expected:
            raise JobError("outlook_source_changed")
    cache = cache or Path.home() / ".cache/huggingface/hub"
    for name, pin in pins["models"].items():
        root = cache / ("models--" + name.replace("/", "--"))
        if (root / "refs/main").read_text().strip() != pin["revision"]:
            raise JobError("model_revision_changed")
        for filename, expected in pin["files"].items():
            if _hash(root / "snapshots" / pin["revision"] / filename) != expected:
                raise JobError("model_bytes_changed")
    return pins


def model_snapshot(pins: dict[str, Any], cache: Path, name: str) -> Path:
    return (
        cache
        / ("models--" + name.replace("/", "--"))
        / "snapshots"
        / pins["models"][name]["revision"]
    )


def pinned_pipeline_config(pins: dict[str, Any], cache: Path) -> dict[str, Any]:
    """Remove mutable Hub identifiers from the verified pipeline configuration."""
    import yaml

    configuration = (
        model_snapshot(pins, cache, "pyannote/speaker-diarization-3.1") / "config.yaml"
    )
    config = yaml.safe_load(configuration.read_bytes())
    if config["pipeline"]["name"] != "pyannote.audio.pipelines.SpeakerDiarization":
        raise JobError("pipeline_changed")
    for key, name in (
        ("segmentation", "pyannote/segmentation-3.0"),
        ("embedding", "pyannote/wespeaker-voxceleb-resnet34-LM"),
    ):
        if config["pipeline"]["params"][key] != name:
            raise JobError("pipeline_changed")
        checkpoint = model_snapshot(pins, cache, name) / "pytorch_model.bin"
        if not checkpoint.is_file():
            raise JobError("model_unavailable")
        config["pipeline"]["params"][key] = str(checkpoint)
    return config


def speaker_suggestion(match: Any) -> dict[str, Any]:
    score = float(match.confidence)
    if not math.isfinite(score) or not -1.000001 <= score <= 1.000001:
        raise JobError("invalid_similarity")
    # Float32 cosine can exceed one by a few ulps. This tolerance does not
    # change a matching threshold or make the score a calibrated probability.
    score = max(-1.0, min(1.0, score))
    named = (
        match.is_match
        and isinstance(match.canonical_name, str)
        and bool(match.canonical_name.strip())
        and isinstance(match.person_id, str)
        and bool(match.person_id.strip())
    )
    return {
        "candidateName": match.canonical_name if named else None,
        "personID": match.person_id if named else None,
        "score": score,
    }


def timed_words(result: Any, duration: float) -> tuple[list[dict[str, Any]], int]:
    """Preserve the full transcript separately when ASR omits exact word timing."""
    if not isinstance(result, dict) or not isinstance(result.get("segments"), list):
        raise JobError("invalid_model_result")
    words: list[dict[str, Any]] = []
    unplaced = 0
    for segment in result["segments"]:
        if not isinstance(segment, dict) or not isinstance(segment.get("words"), list):
            raise JobError("missing_word_timing")
        for word in segment["words"]:
            if not isinstance(word, dict) or not isinstance(word.get("word"), str):
                raise JobError("invalid_model_word")
            lo, hi = word.get("start"), word.get("end")
            if (
                not isinstance(lo, Real)
                or isinstance(lo, bool)
                or not isinstance(hi, Real)
                or isinstance(hi, bool)
                or not 0 <= lo <= hi <= duration + 0.1
            ):
                raise JobError("invalid_model_timing")
            lo, hi = float(lo), min(float(hi), duration)
            if not word["word"].strip() or hi <= lo:
                unplaced += 1
                continue
            words.append({"text": word["word"], "start": lo, "end": hi})
            if len(words) > 4096:
                raise JobError("alignment_limit")
    return words, unplaced


class OutlookBackend:
    def __init__(self, outlook: Path):
        self.cache = (Path.home() / ".cache/huggingface/hub").resolve()
        self.pins = preflight(outlook, self.cache)
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
        sys.path.insert(0, str(outlook))
        configure_torch_runtime()
        import torch
        from pyannote.audio import Pipeline
        from src.intelligence.audio import retrace_diarizer, voice_match

        self.diarizer = retrace_diarizer
        self.voices = voice_match
        self.library = voice_match.load_voice_library()
        # Outlook's singleton resolves mutable Hub IDs. Build from the same
        # verified config with all component paths bound to pinned snapshots.
        self.pipeline = Pipeline.from_pretrained(
            pinned_pipeline_config(self.pins, self.cache),
            token=False,
            cache_dir=str(self.cache),
        )
        if self.pipeline is None:
            raise JobError("pipeline_unavailable")
        self.pipeline.to(
            torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        )

    def transcribe(self, wav: Path, duration: float) -> dict[str, Any]:
        import mlx_whisper
        import numpy as np

        started = time.monotonic()
        name = "mlx-community/whisper-large-v3-mlx"
        model = model_snapshot(self.pins, self.cache, name)
        result = mlx_whisper.transcribe(
            str(wav),
            path_or_hf_repo=str(model),
            language=None,
            task="transcribe",
            verbose=None,
            word_timestamps=True,
            condition_on_previous_text=False,
            hallucination_silence_threshold=2.0,
        )
        text = result.get("text")
        if not isinstance(text, str) or len(text.encode("utf-8")) > 128 * 1024:
            raise JobError("invalid_model_text")
        words, unplaced = timed_words(result, duration)
        waveform, sample_rate = self.diarizer._load_wav_tensor(wav)
        options = (
            {"return_embeddings": True}
            if "return_embeddings" in inspect.signature(self.pipeline.apply).parameters
            else {}
        )
        output = self.pipeline(
            {"waveform": waveform, "sample_rate": sample_rate}, **options
        )
        if isinstance(output, tuple) and len(output) == 2:
            annotation, embeddings = output
        else:
            annotation, embeddings = (
                getattr(output, "speaker_diarization", None),
                getattr(output, "speaker_embeddings", None),
            )
        if annotation is None or embeddings is None:
            raise JobError("diarization_output_unavailable")
        labels = sorted(annotation.labels())
        if len(labels) > 32:
            raise JobError("speaker_limit")
        matrix = np.asarray(embeddings, dtype="float32")
        if labels and (
            matrix.shape != (len(labels), 256) or not np.isfinite(matrix).all()
        ):
            raise JobError("invalid_speaker_embeddings")
        matches = {
            label: self.voices.match_embedding(matrix[index], library=self.library)
            for index, label in enumerate(labels)
        }
        letters = {
            label: chr(65 + index) if index < 26 else "A" + chr(65 + index - 26)
            for index, label in enumerate(labels)
        }
        turns = []
        for segment, _, label in annotation.itertracks(yield_label=True):
            if (
                label not in matches
                or not 0 <= segment.start < segment.end <= duration + 0.1
            ):
                raise JobError("invalid_diarization_turn")
            match = matches[label]
            turns.append(
                {
                    "start": float(segment.start),
                    "end": min(float(segment.end), duration),
                    "cluster": letters[label],
                    **speaker_suggestion(match),
                }
            )
        return {
            "text": text.strip(),
            "language": result.get("language"),
            "words": words,
            "turns": turns,
            "unplacedWords": unplaced,
            "voiceReferenceCount": len(self.library),
            "processingSeconds": time.monotonic() - started,
        }
