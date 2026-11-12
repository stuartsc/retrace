"""Foreground routes preserve native identity and never accept media paths."""
import unittest

from jsonschema import Draft202012Validator, ValidationError
from schemas import SCHEMAS


class ForegroundSchemaTests(unittest.TestCase):
    def setUp(self):
        self.identity = "00000000-0000-4000-8000-000000000001"
        self.transcript = {"version": 1, "nativeStoreID": self.identity,
                           "source": "microphone", "rowID": 1, "snapshotSHA256": "a" * 64}
        self.turn = {"version": 1, "nativeStoreID": self.identity, "jobID": "a" * 64,
                     "resultSHA256": "b" * 64, "turnIndex": 0, "correctionRevision": None}

    def validate(self, operation, arguments):
        Draft202012Validator(SCHEMAS[operation]).validate(
            {"request_id": self.identity, "arguments": arguments})

    def test_exact_transcript_and_turn_navigation_have_distinct_identity(self):
        self.validate("navigation.open", {"kind": "transcript", "reference": self.transcript})
        self.validate("navigation.open", {"kind": "speakerTurn", "reference": self.turn})
        for kind, reference in (("transcript", self.turn), ("speakerTurn", self.transcript)):
            with self.assertRaises(ValidationError):
                self.validate("navigation.open", {"kind": kind, "reference": reference})
        for field, value in (("recordingGeneration", self.identity), ("rowID", 0),
                             ("source", "rewind"), ("snapshotSHA256", "not-a-digest"),
                             ("path", "/private/recording.m4a")):
            with self.assertRaises(ValidationError):
                self.validate("navigation.open", {"kind": "transcript", "reference": {**self.transcript, field: value}})

    def test_playback_requires_turn_identity_and_rejects_legacy_timestamps_paths(self):
        self.validate("playback.control", {"action": "playTurn", "reference": self.turn})
        self.validate("playback.control", {"action": "stop"})
        for arguments in ({"action": "playTurn", "reference": self.transcript},
                          {"action": "playTranscript", "reference": self.transcript},
                          {"action": "playTurn", "reference": {**self.turn, "turnIndex": 4096}},
                          {"action": "stop", "reference": self.turn},
                          {"action": "playTurn", "reference": self.turn, "startTime": 123},
                          {"action": "playTurn", "reference": self.turn, "path": "/recording.m4a"}):
            with self.assertRaises(ValidationError):
                self.validate("playback.control", arguments)


if __name__ == "__main__":
    unittest.main()
