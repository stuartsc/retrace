"""Annotation wire schemas reject implicit deletion and arbitrary path inputs."""

import unittest

from jsonschema import Draft202012Validator, ValidationError
from schemas import SCHEMAS


class AnnotationSchemaTests(unittest.TestCase):
    def test_screenshot_continuation_requires_digest_and_bounds_chunks(self):
        validator = Draft202012Validator(SCHEMAS["screenshot.read"])
        reference = {"storeID": "00000000-0000-4000-8000-000000000001",
                     "source": "native", "observationID": "00000000-0000-4000-8000-000000000002",
                     "frameID": {"value": 1}, "extractionRevision": 1, "blockIDs": []}
        payload = {"request_id": "00000000-0000-4000-8000-000000000003",
                   "arguments": {"reference": reference}}
        validator.validate(payload)
        validator.validate({**payload, "arguments": {"reference": reference, "offset": 512000, "sha256": "a" * 64}})
        for extra in ({"offset": 1}, {"offset": -1}, {"length": 512001}, {"sha256": "wrong"}):
            with self.assertRaises(ValidationError):
                validator.validate({**payload, "arguments": {"reference": reference, **extra}})

    def payload(self, action, **extra):
        return {
            "request_id": "00000000-0000-4000-8000-000000000001",
            "arguments": {
                "selectionID": "00000000-0000-4000-8000-000000000002",
                "expectedRevision": "00000000-0000-4000-8000-000000000003",
                "action": action,
                **extra,
            },
        }

    def test_deletion_is_separate_from_ordinary_write(self):
        Draft202012Validator(SCHEMAS["tags.write"]).validate(
            self.payload("add", text="Authored tag")
        )
        with self.assertRaises(ValidationError):
            Draft202012Validator(SCHEMAS["tags.write"]).validate(
                self.payload("delete", id=42)
            )
        deletion = SCHEMAS["tags.remove"]
        Draft202012Validator(deletion).validate(self.payload("delete", id=42))
        self.assertEqual(deletion["properties"]["mode"]["default"], "preview")

    def test_comment_write_has_no_attachment_or_path_interface(self):
        validator = Draft202012Validator(SCHEMAS["comments.write"])
        validator.validate(self.payload("create", text="Authored note"))
        for field in ("path", "filePath", "attachments", "author"):
            with self.assertRaises(ValidationError):
                validator.validate(self.payload("create", text="Authored note", **{field: "untrusted"}))
        with self.assertRaises(ValidationError):
            validator.validate(self.payload("create", text="x" * 16385))

    def test_tag_text_uses_its_native_limit_without_restricting_comments(self):
        validator = Draft202012Validator(SCHEMAS["tags.write"])
        validator.validate(self.payload("add", text="x" * 256))
        with self.assertRaises(ValidationError):
            validator.validate(self.payload("add", text="x" * 257))
        Draft202012Validator(SCHEMAS["comments.write"]).validate(
            self.payload("create", text="x" * 16384)
        )

    def test_backlog_is_bounded_empty_argument_read(self):
        validator = Draft202012Validator(SCHEMAS["backlog.read"])
        payload = {"request_id": self.payload("add")["request_id"], "arguments": {}}
        validator.validate(payload)
        payload["arguments"] = {"sql": "untrusted"}
        with self.assertRaises(ValidationError):
            validator.validate(payload)

    def test_capture_settings_only_expose_supported_bounded_changes(self):
        validator = Draft202012Validator(SCHEMAS["settings.update"])
        payload = {"request_id": self.payload("add")["request_id"], "arguments": {
            "expectedRevision": "00000000-0000-4000-8000-000000000003",
            "captureIntervalSeconds": 10, "redactWindowTitlePatterns": ["Authored private"]}}
        validator.validate(payload)
        for field in ("showCursor", "excludePrivateWindows", "path", "shell"):
            with self.assertRaises(ValidationError):
                validator.validate({**payload, "arguments": {**payload["arguments"], field: True}})
        with self.assertRaises(ValidationError):
            validator.validate({**payload, "arguments": {**payload["arguments"], "excludedAppBundleIDs": ["x"] * 257}})

    def test_source_access_requires_preview_and_never_accepts_paths(self):
        validator = Draft202012Validator(SCHEMAS["sources.update"])
        payload = {"request_id": self.payload("add")["request_id"], "arguments": {
            "source": "rewind", "enabled": False,
            "expectedRevision": "00000000-0000-4000-8000-000000000003"}}
        validator.validate(payload)
        self.assertEqual(SCHEMAS["sources.update"]["properties"]["mode"]["default"], "preview")
        for field in ("path", "password", "database"):
            with self.assertRaises(ValidationError):
                validator.validate({**payload, "arguments": {**payload["arguments"], field: "untrusted"}})

    def test_audio_configuration_requires_complete_revision_checked_values(self):
        validator = Draft202012Validator(SCHEMAS["audio.settings.update"])
        payload = {"request_id": self.payload("add")["request_id"], "arguments": {
            "microphoneEnabled": False, "systemAudioEnabled": False,
            "expectedRevision": "00000000-0000-4000-8000-000000000003"}}
        validator.validate(payload)
        for field in ("microphoneEnabled", "expectedRevision"):
            with self.assertRaises(ValidationError):
                validator.validate({**payload, "arguments": {k: v for k, v in payload["arguments"].items() if k != field}})
        with self.assertRaises(ValidationError):
            validator.validate({**payload, "arguments": {**payload["arguments"], "hasConsentedToMeetingRecording": True}})
