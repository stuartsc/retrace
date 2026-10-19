"""Real manifests, files and AAC decoding; no live recording or user stores."""

from __future__ import annotations

import hashlib
import json
import math
import shutil
import struct
import subprocess
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

from audio_worker.contract import (
    Job,
    JobError,
    decode_window,
    load_job,
    load_result,
    publish_result,
)
from audio_worker.speakers import align_words


class ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.media = self.root / "media"
        self.media.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def manifest(self, **changes: object) -> dict:
        payload = {
            "version": 1,
            "storeID": "4a641ef9-789a-44eb-aa3a-aea20885c62d",
            "source": "microphone",
            "generation": 1,
            "startMilliseconds": 1_800_000_000_000,
            "media": [
                {
                    "sha256": "a" * 64,
                    "byteCount": 100,
                    "offsetSamples": 0,
                    "countSamples": 32_000,
                    "startMilliseconds": 1_800_000_000_000,
                    "mediaID": "b" * 64,
                }
            ],
        }
        payload.update(changes)
        return payload

    def save_job(self, payload: dict) -> Path:
        data = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        path = self.root / (hashlib.sha256(data).hexdigest() + ".job.json")
        path.write_bytes(data)
        return path

    def test_manifest_identity_and_sample_ranges_are_validated_before_media_reads(
        self,
    ) -> None:
        path = self.save_job(self.manifest())
        job = load_job(path)
        self.assertEqual(job.sample_count, 32_000)
        self.assertEqual(job.end_ms, 1_800_000_002_000)
        path.write_text(path.read_text().replace('"generation":1', '"generation":2'))
        with self.assertRaisesRegex(JobError, "request_digest"):
            load_job(path)
        for change in (
            {"version": 9},
            {"generation": True},
            {"source": "../system"},
            {"startMilliseconds": float("nan")},
            {"media": []},
        ):
            with self.subTest(change=change), self.assertRaises(JobError):
                load_job(self.save_job(self.manifest(**change)))

    def test_gaps_and_overlapping_source_samples_cannot_be_silently_stitched(
        self,
    ) -> None:
        original = self.manifest()
        first = original["media"][0]
        for start in (1_800_000_001_999, 1_800_000_002_100):
            second = dict(first, startMilliseconds=start)
            with (
                self.subTest(start=start),
                self.assertRaisesRegex(JobError, "discontinuous"),
            ):
                Job.parse(self.manifest(media=[first, second]), "a" * 64)
        second = dict(first, startMilliseconds=1_800_000_002_000)
        with self.assertRaisesRegex(JobError, "source_range"):
            Job.parse(self.manifest(media=[first, second]), "a" * 64)
        second["offsetSamples"] = 32_000
        self.assertEqual(
            Job.parse(self.manifest(media=[first, second]), "a" * 64).sample_count,
            64_000,
        )
        for change in (
            {"sha256": "c" * 64},
            {"byteCount": 101},
            {"offsetSamples": 33_000},
        ):
            with (
                self.subTest(change=change),
                self.assertRaisesRegex(JobError, "source_range"),
            ):
                Job.parse(
                    self.manifest(media=[first, dict(second, **change)]), "a" * 64
                )

    @unittest.skipUnless(shutil.which("ffmpeg"), "Native AAC acceptance needs ffmpeg")
    def test_real_aac_ranges_decode_once_with_no_added_gap_or_encoder_padding(
        self,
    ) -> None:
        wav = self.root / "authored.wav"
        values = [
            int(10_000 * math.sin(2 * math.pi * 440 * i / 16_000))
            for i in range(32_000)
        ]
        with wave.open(str(wav), "wb") as writer:
            writer.setparams((1, 2, 16_000, 0, "NONE", "not compressed"))
            writer.writeframes(struct.pack("<32000h", *values))
        encoded = self.root / "authored.m4a"
        subprocess.run(
            [
                "ffmpeg",
                "-nostdin",
                "-v",
                "error",
                "-i",
                str(wav),
                "-c:a",
                "aac",
                str(encoded),
            ],
            check=True,
            timeout=20,
        )
        data = encoded.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        (self.media / (digest + ".m4a")).write_bytes(data)
        base = self.manifest()["media"][0]
        ranges = [
            dict(base, sha256=digest, byteCount=len(data), countSamples=16_000),
            dict(
                base,
                sha256=digest,
                byteCount=len(data),
                offsetSamples=16_000,
                countSamples=16_000,
                startMilliseconds=1_800_000_001_000,
            ),
        ]
        job = Job.parse(self.manifest(media=ranges), "a" * 64)
        output = self.root / "window.wav"
        decode_window(job, self.media, output)
        with wave.open(str(output), "rb") as reader:
            self.assertEqual(reader.getnframes(), 32_000)
            self.assertEqual(reader.getparams()[:3], (1, 2, 16_000))
            samples = struct.unpack("<32000h", reader.readframes(32_000))
        self.assertGreater(max(samples), 5_000)
        # Rewriting the original inode after verification must not change the
        # waveform handed to the decoder. The decoder operates on a snapshot.
        actual_run = subprocess.run

        def mutate_original_then_decode(*args, **kwargs):
            (self.media / (digest + ".m4a")).write_bytes(b"changed after hashing")
            return actual_run(*args, **kwargs)

        with patch(
            "audio_worker.contract.subprocess.run",
            side_effect=mutate_original_then_decode,
        ):
            decode_window(job, self.media, self.root / "snapshot.wav")
        self.assertEqual(output.read_bytes(), (self.root / "snapshot.wav").read_bytes())
        # The decoder must recheck the immutable bytes, even if the path is reused.
        (self.media / (digest + ".m4a")).write_bytes(b"broken")
        with self.assertRaises(JobError):
            decode_window(job, self.media, self.root / "bad.wav")

    def test_symlink_media_and_duplicate_result_overwrite_are_rejected(self) -> None:
        target = self.root / "private"
        target.write_bytes(b"secret")
        (self.media / ("a" * 64 + ".m4a")).symlink_to(target)
        job = Job.parse(self.manifest(), "b" * 64)
        with self.assertRaises(JobError):
            decode_window(job, self.media, self.root / "bad.wav")
        result = {
            "version": 1,
            "jobID": job.identifier,
            "status": "complete",
            "segments": [],
        }
        out = self.root / "results"
        publish_result(out, job.identifier, result)
        publish_result(out, job.identifier, result)
        with self.assertRaisesRegex(JobError, "result_conflict"):
            publish_result(out, job.identifier, dict(result, status="failed"))
        self.assertEqual(
            json.loads((out / (job.identifier + ".json")).read_text()), result
        )

    def test_existing_result_requires_a_bounded_regular_file_with_matching_identity(
        self,
    ):
        job = load_job(self.save_job(self.manifest()))
        path = self.root / (job.identifier + ".json")
        valid = dict(
            version=1,
            jobID=job.identifier,
            storeID=job.store_id,
            generation=job.generation,
            source=job.source,
            status="complete",
            startMilliseconds=job.start_ms,
            endMilliseconds=job.end_ms,
            sampleCount=job.sample_count,
            automaticNamesCalibrated=False,
            text="",
            segments=[],
            models=json.loads(
                (Path(__file__).parents[1] / "runtime-pins.json").read_text()
            ),
            language="en",
            unplacedWords=0,
            voiceReferenceCount=1,
            processingSeconds=0.5,
            totalSeconds=1.0,
            processPeakResidentBytes=1024,
        )
        path.write_text(json.dumps(valid))
        self.assertEqual(load_result(path, job), valid)
        for contents in (
            "{broken",
            json.dumps(dict(valid, generation=2)),
            json.dumps(dict(valid, automaticNamesCalibrated=True)),
            "x" * (2 * 1024 * 1024 + 1),
            json.dumps(dict(valid, models={})),
            json.dumps(
                dict(
                    valid,
                    segments=[
                        dict(
                            start=0,
                            end=1,
                            speakerID=job.identifier + ":cluster:A",
                            speakerStatus="unknown",
                        )
                    ],
                )
            ),
            json.dumps(
                dict(
                    valid,
                    segments=[
                        dict(
                            start=0,
                            end=1,
                            text="Yes",
                            speakerLabel="Overlapping voices",
                            speakerID=job.identifier + ":state:overlap",
                            speakerStatus="overlap",
                            candidateName="Stuart",
                            personID="p1",
                            similarity=999,
                        )
                    ],
                )
            ),
            json.dumps(dict(valid, text="\ud800")),
        ):
            path.write_text(contents)
            with self.subTest(prefix=contents[:10]), self.assertRaises(JobError):
                load_result(path, job)
        path.unlink()
        path.mkdir()
        with self.assertRaisesRegex(JobError, "invalid_existing_result"):
            load_result(path, job)
        path.rmdir()
        target = self.root / "target.json"
        target.write_text(json.dumps(valid))
        path.symlink_to(target)
        with self.assertRaisesRegex(JobError, "invalid_existing_result"):
            load_result(path, job)

    def test_word_alignment_does_not_assign_a_whole_sentence_to_one_speaker(
        self,
    ) -> None:
        words = [
            dict(text="Hello", start=0.0, end=0.4),
            dict(text="Stuart", start=0.5, end=0.9),
            dict(text="Yes", start=1.0, end=1.3),
            dict(text="Overlap", start=1.4, end=1.9),
        ]
        turns = [
            dict(
                start=0.0,
                end=0.95,
                cluster="A",
                candidateName="Stuart",
                personID="p1",
                score=0.85,
            ),
            dict(
                start=1.0,
                end=2.0,
                cluster="B",
                candidateName=None,
                personID=None,
                score=0.1,
            ),
            dict(
                start=1.5,
                end=2.0,
                cluster="A",
                candidateName="Stuart",
                personID="p1",
                score=0.85,
            ),
        ]
        result = align_words(words, turns, job_id="a" * 64)
        self.assertEqual(
            [s["text"] for s in result], ["Hello Stuart", "Yes", "Overlap"]
        )
        self.assertEqual(result[0]["speakerLabel"], "Speaker A")
        self.assertEqual(result[0]["candidateName"], "Stuart")
        self.assertEqual(result[0]["speakerStatus"], "suggested")
        self.assertEqual(result[1]["speakerLabel"], "Speaker B")
        self.assertIsNone(
            result[2]["personID"],
            "Overlap must not turn a guessed person into a known speaker",
        )
        self.assertEqual(result[2]["speakerStatus"], "overlap")
        self.assertNotEqual(result[0]["speakerID"], result[1]["speakerID"])

    def test_invalid_turns_and_words_cannot_create_a_person_attribution(self) -> None:
        word = dict(text="Yes", start=0.0, end=1.0)
        turn = dict(
            start=0.0,
            end=1.0,
            cluster="A",
            candidateName="Stuart",
            personID="p1",
            score=0.8,
        )
        for change in (
            {"start": float("nan"), "end": float("nan")},
            {"end": float("inf")},
            {"score": float("nan")},
            {"score": 1.1},
            {"cluster": []},
            {"personID": ""},
            {"candidateName": 3},
            {"start": True},
        ):
            with self.subTest(change=change), self.assertRaises(JobError):
                align_words([word], [dict(turn, **change)], job_id="a" * 64)
        for malformed in ({}, dict(word, text=None), dict(word, end=True), "word"):
            with self.subTest(word=malformed), self.assertRaises(JobError):
                align_words([malformed], [turn], job_id="a" * 64)

    def test_duplicate_and_overlapping_turns_do_not_inflate_coverage(self) -> None:
        word = dict(text="Yes", start=0.0, end=1.0)
        turn = dict(
            start=0.0,
            end=0.2,
            cluster="A",
            candidateName="Stuart",
            personID="p1",
            score=0.8,
        )
        for turns in ([turn] * 3, [turn, dict(turn, start=0.1, end=0.4)]):
            result = align_words([word], turns, job_id="a" * 64)
            self.assertEqual(result[0]["speakerStatus"], "unknown")
            self.assertIsNone(result[0]["personID"])

    def test_duplicate_json_keys_are_rejected(self) -> None:
        data = (
            json.dumps(self.manifest())
            .encode()
            .replace(b'"version": 1', b'"version": 9, "version": 1')
        )
        path = self.root / (hashlib.sha256(data).hexdigest() + ".job.json")
        path.write_bytes(data)
        with self.assertRaisesRegex(JobError, "duplicate_key"):
            load_job(path)


if __name__ == "__main__":
    unittest.main()
