"""Model-output boundary checks; native inference has a separate explicit receipt."""

import unittest
import json
import tempfile
from fractions import Fraction
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from audio_worker.contract import JobError
from audio_worker.outlook_backend import (
    timed_words,
    pinned_pipeline_config,
    speaker_suggestion,
)


class BackendContractTests(unittest.TestCase):
    def test_pipeline_consumes_explicit_snapshot_files_despite_cache_overrides(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            names = [
                "pyannote/speaker-diarization-3.1",
                "pyannote/segmentation-3.0",
                "pyannote/wespeaker-voxceleb-resnet34-LM",
            ]
            pins = {"models": {name: {"revision": "a" * 40} for name in names}}
            snapshots = [
                root / ("models--" + name.replace("/", "--")) / "snapshots" / ("a" * 40)
                for name in names
            ]
            for snapshot in snapshots:
                snapshot.mkdir(parents=True)
            (snapshots[0] / "config.yaml").write_text(
                json.dumps(
                    {
                        "pipeline": {
                            "name": "pyannote.audio.pipelines.SpeakerDiarization",
                            "params": {"segmentation": names[1], "embedding": names[2]},
                        },
                        "params": {"clustering": {"threshold": 0.7045654963945799}},
                    }
                )
            )
            for snapshot in snapshots[1:]:
                (snapshot / "pytorch_model.bin").write_bytes(b"authored path fixture")
            with patch.dict(
                "os.environ",
                {"HF_HUB_CACHE": str(root / "wrong"), "HF_HOME": str(root / "other")},
            ):
                config = pinned_pipeline_config(pins, root)
            for key, snapshot in zip(("segmentation", "embedding"), snapshots[1:]):
                self.assertEqual(
                    config["pipeline"]["params"][key],
                    str(snapshot / "pytorch_model.bin"),
                )
            self.assertEqual(
                config["params"]["clustering"]["threshold"], 0.7045654963945799
            )
            (snapshots[1] / "pytorch_model.bin").unlink()
            with self.assertRaisesRegex(JobError, "model_unavailable"):
                pinned_pipeline_config(pins, root)

    def test_unnamed_matches_remain_unknown_and_float_roundoff_is_bounded(self):
        unnamed = SimpleNamespace(
            is_match=True,
            canonical_name=None,
            person_id="p1",
            confidence=1.0000001192092896,
        )
        self.assertEqual(
            speaker_suggestion(unnamed),
            {"candidateName": None, "personID": None, "score": 1.0},
        )
        named = SimpleNamespace(
            is_match=True, canonical_name="Stuart", person_id="p1", confidence=0.8
        )
        self.assertEqual(speaker_suggestion(named)["candidateName"], "Stuart")
        for score in (float("nan"), float("inf"), 1.001, -1.01):
            named.confidence = score
            with (
                self.subTest(score=score),
                self.assertRaisesRegex(JobError, "invalid_similarity"),
            ):
                speaker_suggestion(named)

    def test_native_real_scalar_timestamps_are_normalized_to_json_floats(self):
        words, _ = timed_words(
            {
                "segments": [
                    {
                        "words": [
                            {
                                "word": "Yes",
                                "start": Fraction(1, 10),
                                "end": Fraction(1, 2),
                            }
                        ]
                    }
                ]
            },
            1.0,
        )
        self.assertEqual(words, [{"text": "Yes", "start": 0.1, "end": 0.5}])
        self.assertIs(type(words[0]["start"]), float)

    def test_word_timing_preserves_order_and_reports_untimed_punctuation(self):
        result = {
            "text": "Forty two.",
            "segments": [
                {
                    "words": [
                        {"word": "Forty", "start": 0.1, "end": 0.5},
                        {"word": "two", "start": 0.6, "end": 0.9},
                        {"word": ".", "start": 0.9, "end": 0.9},
                    ]
                }
            ],
        }
        words, unplaced = timed_words(result, 1.0)
        self.assertEqual([word["text"] for word in words], ["Forty", "two"])
        self.assertEqual(unplaced, 1)
        self.assertEqual(result["text"], "Forty two.")

    def test_missing_nonfinite_and_out_of_window_timing_is_not_silence(self):
        for result in (
            {},
            {"segments": [{}]},
            {
                "segments": [
                    {"words": [{"word": "Yes", "start": float("nan"), "end": 1.0}]}
                ]
            },
            {"segments": [{"words": [{"word": "Yes", "start": 0, "end": 10}]}]},
        ):
            with self.subTest(result=result), self.assertRaises(JobError):
                timed_words(result, 1.0)
