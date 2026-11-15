import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from package_audio_worker_runtime import package


class WorkerPackagingTests(unittest.TestCase):
    def fixture(self, root):
        source = root / "scripts"
        for name in ("audio_worker", "retrace_companion"):
            (source / name).mkdir(parents=True)
            (source / name / "__init__.py").write_text("")
        (source / "retrace_companion/local_job.py").write_text("# authored fixture\n")
        (source / "audio_worker/runtime-pins.json").write_text("{}\n")
        (source / "audio_worker/tests").mkdir()
        (source / "audio_worker/tests/private.txt").write_text("do not package")
        bundle = root / "Candidate.app"
        bundle.mkdir()
        return source, bundle

    def test_only_worker_inputs_are_packaged_and_bound_to_a_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, bundle = self.fixture(Path(temporary).resolve())
            manifest = package(bundle, source)
            target = bundle / "Contents/Resources/AudioWorker"
            self.assertEqual(len(manifest), 4)
            self.assertFalse((target / "audio_worker/tests").exists())
            for path, digest in manifest.items():
                self.assertEqual(
                    hashlib.sha256((target / path).read_bytes()).hexdigest(), digest
                )
            self.assertEqual(
                json.loads((target / "manifest.json").read_text()), manifest
            )
            with self.assertRaises(ValueError):
                package(bundle, source)

    def test_linked_source_is_rejected_before_destination_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, bundle = self.fixture(root)
            (source / "audio_worker/escape.py").symlink_to(
                source / "retrace_companion/local_job.py"
            )
            with self.assertRaises(ValueError):
                package(bundle, source)
            self.assertFalse((bundle / "Contents/Resources/AudioWorker").exists())

    def test_linked_resource_directory_cannot_write_outside_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, bundle = self.fixture(root)
            (bundle / "Contents").mkdir()
            (bundle / "Contents/Resources").symlink_to(root)
            with self.assertRaises(ValueError):
                package(bundle, source)
            self.assertFalse((root / "AudioWorker").exists())
