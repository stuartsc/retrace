"""Private SQLite/filesystem transport receipts and authored, noncontiguous evidence."""

import hashlib
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

from retrace_companion.contract import CompanionError, encode, validate_job
from retrace_companion.queue import CompanionQueue, publish_file
from retrace_companion.context import propose_context


class CompanionTests(unittest.TestCase):
    def test_v23_reference_requires_full_row_digest_and_no_invented_generation(self):
        job = self.job()
        item = job["context"]["evidence"][0]
        item["reference"] = {
            "sourceStoreID": self.store,
            "kind": "v23Transcript",
            "v23Transcript": {
                "version": 1,
                "nativeStoreID": self.store,
                "source": "microphone",
                "rowID": 17,
                "snapshotSHA256": "a" * 64,
            },
        }
        validate_job(job)
        item["reference"]["v23Transcript"]["recordingGeneration"] = str(uuid.uuid4())
        with self.assertRaises(CompanionError):
            validate_job(job)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.queue = CompanionQueue(self.root)
        self.store = str(uuid.uuid4())

    def tearDown(self):
        self.queue.close()
        self.temporary.cleanup()

    def job(self, observed=1_800_000_000_000):
        return {
            "version": 1,
            "kind": "context",
            "sourceStoreID": self.store,
            "observedAt": observed,
            "context": {
                "markerID": str(uuid.uuid4()),
                "markerRevision": str(uuid.uuid4()),
                "snapshotID": str(uuid.uuid4()),
                "query": "Remember the pricing decision",
                "verbatimExplanation": "The earlier budget note explains the pricing decision.",
                "developing": True,
                "incomplete": False,
                "evidence": [
                    self.evidence("earlier", observed - 600_000, "Budget decision"),
                    self.evidence("later", observed + 240_000, "Pricing rationale"),
                    self.evidence("noise", observed, "Unrelated weather"),
                ],
            },
        }

    def evidence(self, identity, start, text):
        return {
            "id": identity,
            "start": start,
            "end": start + 1000,
            "text": text,
            "reference": {
                "sourceStoreID": self.store,
                "kind": "screen",
                "screen": {
                    "storeID": self.store,
                    "source": "native",
                    "observationID": str(uuid.uuid4()),
                    "frameID": {"value": 1},
                    "extractionRevision": 1,
                    "blockIDs": [],
                },
            },
        }

    def publish(self, job):
        data = encode(job)
        identifier = hashlib.sha256(data).hexdigest()
        self.queue.publish(identifier, data)
        return identifier

    def test_publication_reopen_and_result_ack_are_durable_idempotent(self):
        job = self.job()
        identifier = self.publish(job)
        self.assertEqual(self.publish(job), identifier)
        claimed = self.queue.claim()
        self.assertEqual(claimed["jobID"], identifier)
        result = {
            "version": 1,
            "jobID": identifier,
            "kind": "context",
            "sourceStoreID": self.store,
            "contextProposal": propose_context(
                job, identifier, rank=lambda q, texts: [0.9, 0.8, 0.1]
            ),
        }
        self.queue.complete(identifier, encode(result))
        self.queue.close()
        self.queue = CompanionQueue(self.root)
        retained = self.queue.result(identifier)
        self.assertEqual(json.loads(retained), result)
        with self.assertRaises(CompanionError):
            self.queue.acknowledge(identifier, "0" * 64)
        digest = hashlib.sha256(retained).hexdigest()
        self.queue.acknowledge(identifier, digest)
        self.queue.acknowledge(identifier, digest)
        self.assertEqual(self.queue.status(identifier)["state"], "acknowledged")
        self.assertIsNone(self.queue.claim())

    def test_fresh_work_precedes_old_and_restart_requeues_unfinished_claim(self):
        old = self.publish(self.job(observed=1_700_000_000_000))
        new = self.publish(self.job(observed=1_800_000_000_000))
        self.assertEqual(self.queue.claim()["jobID"], new)
        self.queue.recover_interrupted()
        self.assertEqual(self.queue.claim()["jobID"], new)
        self.queue.fail(new, "offline")
        self.assertEqual(self.queue.claim()["jobID"], old)

    def test_conflicting_publication_or_result_never_overwrites(self):
        job = self.job()
        identifier = self.publish(job)
        changed = self.job()
        with self.assertRaises(CompanionError):
            self.queue.publish(identifier, encode(changed))
        self.queue.claim()
        result = {
            "version": 1,
            "jobID": identifier,
            "kind": "context",
            "sourceStoreID": self.store,
            "contextProposal": propose_context(
                job, identifier, rank=lambda q, texts: [0.9, 0.8, 0.1]
            ),
        }
        self.queue.complete(identifier, encode(result))
        changed_result = dict(result, sourceStoreID=str(uuid.uuid4()))
        with self.assertRaises(CompanionError):
            self.queue.complete(identifier, encode(changed_result))
        self.assertEqual(json.loads(self.queue.result(identifier)), result)

    def test_context_uses_supporting_intervals_without_fixed_time_window(self):
        job = self.job()
        result = propose_context(
            job, "a" * 64, rank=lambda q, texts: [0.95, 0.85, 0.01]
        )
        self.assertEqual(
            [r["supportIDs"] for r in result["ranges"]], [["earlier"], ["later"]]
        )
        self.assertEqual(
            result["ranges"][0]["start"], job["context"]["evidence"][0]["start"]
        )
        self.assertEqual(
            result["ranges"][1]["start"], job["context"]["evidence"][1]["start"]
        )
        self.assertTrue(result["developing"])
        self.assertEqual(
            result["verbatimExplanation"], job["context"]["verbatimExplanation"]
        )

    def test_context_unavailable_and_unrelated_input_have_explicit_coverage(self):
        job = self.job()
        job["context"]["incomplete"] = True
        result = propose_context(
            job, "a" * 64, rank=lambda q, texts: [0.01] * len(texts)
        )
        self.assertEqual(result["ranges"], [])
        self.assertTrue(result["incomplete"])

    def test_cross_store_unbounded_or_duplicate_evidence_rejected(self):
        job = self.job()
        job["context"]["evidence"][0]["reference"]["sourceStoreID"] = str(uuid.uuid4())
        with self.assertRaises(CompanionError):
            validate_job(job)
        job = self.job()
        job["context"]["evidence"] *= 100
        with self.assertRaises(CompanionError):
            validate_job(job)
        job = self.job()
        job["context"]["evidence"][1]["id"] = "earlier"
        with self.assertRaises(CompanionError):
            validate_job(job)

    def test_capacity_and_symlinks_fail_before_publication(self):
        self.queue.max_jobs = 1
        self.publish(self.job())
        with self.assertRaises(CompanionError):
            self.publish(self.job())
        target = self.root / "outside"
        target.write_bytes(b"private")
        digest = hashlib.sha256(b"private").hexdigest()
        (self.root / "objects" / (digest + ".m4a")).symlink_to(target)
        with self.assertRaises(CompanionError):
            self.queue.publish_object(digest, b"private")

    def test_foreign_database_is_rejected_without_changing_schema(self):
        foreign = self.root / "foreign"
        foreign.mkdir(mode=0o700)
        path = foreign / "delivery.sqlite"
        database = sqlite3.connect(path)
        database.execute("CREATE TABLE untouched(value TEXT)")
        database.commit()
        database.close()
        path.chmod(0o600)
        with self.assertRaisesRegex(CompanionError, "incompatible_database"):
            CompanionQueue(foreign)
        database = sqlite3.connect(path)
        self.assertEqual(
            database.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall(),
            [("untouched",)],
        )
        self.assertEqual(database.execute("PRAGMA application_id").fetchone()[0], 0)
        database.close()

    def test_simultaneous_first_startup_serializes_metadata_and_schema_publication(
        self,
    ):
        root = self.root / "simultaneous-startup"
        metadata_entered = threading.Event()
        release_metadata = threading.Event()
        second_attempted = threading.Event()
        second_finished = threading.Event()
        connect = sqlite3.connect
        connections = []

        class ObservedConnection(sqlite3.Connection):
            def execute(connection, sql, parameters=()):
                if (
                    sql == "PRAGMA user_version"
                    and len(connections) == 1
                    and not metadata_entered.is_set()
                ):
                    # Hold the first owner inside the real metadata transaction.
                    # The second startup must not inspect a different generation.
                    metadata_entered.set()
                    self.assertTrue(connection.in_transaction)
                    if not release_metadata.wait(3):
                        raise AssertionError("Metadata test boundary was not released")
                return super().execute(sql, parameters)

        def observed_connect(*args, **kwargs):
            connection = connect(*args, factory=ObservedConnection, **kwargs)
            connections.append(connection)
            return connection

        def start(second=False):
            if second:
                second_attempted.set()
            queue = CompanionQueue(root)
            try:
                return queue.db.execute("PRAGMA user_version").fetchone()[0]
            finally:
                queue.close()
                if second:
                    second_finished.set()

        with patch("retrace_companion.queue.sqlite3.connect", observed_connect):
            with ThreadPoolExecutor(max_workers=2) as executor:
                first = executor.submit(start)
                try:
                    self.assertTrue(metadata_entered.wait(3))
                    second = executor.submit(start, True)
                    self.assertTrue(second_attempted.wait(3))
                    self.assertFalse(second_finished.wait(0.05))
                finally:
                    release_metadata.set()
                self.assertEqual(first.result(timeout=3), 2)
                self.assertEqual(second.result(timeout=3), 2)
        with connect(root / "delivery.sqlite") as database:
            self.assertEqual(
                database.execute("PRAGMA application_id").fetchone()[0], 1381253968
            )
            self.assertEqual(
                database.execute("PRAGMA journal_mode").fetchone()[0], "wal"
            )
            self.assertEqual(
                database.execute("SELECT count(*) FROM jobs").fetchone()[0], 0
            )

    def test_concurrent_initializers_share_one_private_database(self):
        root = self.root / "concurrent-startup"
        barrier = threading.Barrier(8)

        def start():
            barrier.wait(timeout=3)
            queue = CompanionQueue(root)
            try:
                return queue.db.execute("PRAGMA user_version").fetchone()[0]
            finally:
                queue.close()

        with ThreadPoolExecutor(max_workers=8) as executor:
            self.assertEqual(list(executor.map(lambda _: start(), range(8))), [2] * 8)
        self.assertEqual((root / "delivery.sqlite").stat().st_mode & 0o077, 0)

    def test_held_initialization_lock_times_out_and_retry_recovers(self):
        descriptor = os.open(self.root / ".initialization.lock", os.O_RDWR)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            started = time.monotonic()
            with self.assertRaisesRegex(CompanionError, "storage_unavailable"):
                CompanionQueue(self.root)
            elapsed = time.monotonic() - started
            self.assertGreaterEqual(elapsed, 0.9)
            self.assertLess(elapsed, 2.0)
        finally:
            os.close(descriptor)
        reopened = CompanionQueue(self.root)
        try:
            self.assertIsNone(reopened.claim())
        finally:
            reopened.close()

    def test_startup_rejects_an_aliased_initialization_lock(self):
        root = self.root / "unsafe-startup"
        root.mkdir(mode=0o700)
        original = root / "outside-lock"
        original.write_bytes(b"Do not modify this file")
        original.chmod(0o600)
        os.link(original, root / ".initialization.lock")
        with self.assertRaisesRegex(CompanionError, "unsafe_initialization_lock"):
            CompanionQueue(root)
        self.assertFalse((root / "delivery.sqlite").exists())
        self.assertEqual(original.read_bytes(), b"Do not modify this file")

    def test_support_identity_is_stable_across_proposal_revisions(self):
        job = self.job()
        first = propose_context(job, "a" * 64, rank=lambda q, texts: [0.9, 0.0, 0.0])
        job["context"]["snapshotID"] = str(uuid.uuid4())
        job["context"]["markerRevision"] = str(uuid.uuid4())
        second = propose_context(job, "b" * 64, rank=lambda q, texts: [0.95, 0.0, 0.0])
        self.assertEqual(first["ranges"][0]["id"], second["ranges"][0]["id"])

    def test_tiny_orphan_objects_cannot_bypass_count_quota(self):
        self.queue.max_objects = 2
        for content in (b"one", b"two"):
            self.queue.publish_object(hashlib.sha256(content).hexdigest(), content)
        with self.assertRaisesRegex(CompanionError, "media_capacity"):
            self.queue.publish_object(hashlib.sha256(b"three").hexdigest(), b"three")
        self.queue.publish_object(hashlib.sha256(b"one").hexdigest(), b"one")

    def speaker_job(self, data=b"authored staged audio", observed=1_800_000_000_000):
        sha = hashlib.sha256(data).hexdigest()
        return {
            "version": 1,
            "kind": "speaker",
            "sourceStoreID": self.store,
            "observedAt": observed,
            "speaker": {
                "sourceIdentity": {
                    "recordingGeneration": "25ba64ac-c8f0-4935-93d4-8098c732f710",
                    "continuityID": "d2cf49ae-668b-4a83-81e4-dd9a0da19f0a",
                    "startSample": 0,
                    "sampleCount": 16000,
                    "sampleRate": 16000,
                    "approximateOrigin": observed,
                },
                "firstPassText": "Original first-pass text",
                "firstPassReferences": [
                    {
                        "version": 1,
                        "nativeStoreID": self.store,
                        "source": "microphone",
                        "rowID": 1,
                        "snapshotSHA256": "e" * 64,
                    }
                ],
                "media": [
                    {
                        "sha256": sha,
                        "byteCount": len(data),
                        "mediaID": "b" * 64,
                        "offsetSamples": 0,
                        "countSamples": 16000,
                        "sourceStartSample": 0,
                    }
                ],
            },
        }

    def finish(self, job_id):
        job = self.queue.request(job_id)
        self.assertEqual(self.queue.claim()["jobID"], job_id)
        result = {
            "version": 1,
            "jobID": job_id,
            "kind": job["kind"],
            "sourceStoreID": self.store,
        }
        if job["kind"] == "context":
            result["contextProposal"] = propose_context(
                job, job_id, rank=lambda q, t: [0.9, 0.8, 0.1]
            )
        else:
            result["speakerEnrichment"] = {
                "sourceIdentity": job["speaker"]["sourceIdentity"],
                "firstPassSHA256": hashlib.sha256(
                    job["speaker"]["firstPassText"].encode()
                ).hexdigest(),
                "enhancedText": "Separate enriched text",
                "turns": [],
                "automaticNamesCalibrated": False,
                "modelFingerprint": "c" * 64,
            }
        data = encode(result)
        self.queue.complete(job_id, data)
        return hashlib.sha256(data).hexdigest(), data

    def test_ack_archives_request_frees_active_capacity_and_preserves_replay(self):
        self.queue.max_jobs = 1
        job = self.job()
        job_id = self.publish(job)
        digest, result = self.finish(job_id)
        self.queue.acknowledge(job_id, digest)
        self.assertEqual(
            self.queue.db.execute(
                "SELECT payload FROM jobs WHERE id=?", (job_id,)
            ).fetchone()[0],
            b"",
        )
        next_id = self.publish(self.job())
        self.assertNotEqual(next_id, job_id)
        self.assertEqual(self.publish(job), job_id)
        self.assertEqual(self.queue.status(job_id)["attempts"], 1)
        self.assertEqual(self.queue.result(job_id), result)
        self.queue.close()
        self.queue = CompanionQueue(self.root)
        self.assertEqual(self.queue.request(job_id), job)
        self.assertEqual(self.queue.claim()["jobID"], next_id)
        self.assertIsNone(self.queue.claim())

    def test_staged_media_survives_active_reference_then_ack_collects_only_copy(self):
        data = b"authored staged audio"
        sha = hashlib.sha256(data).hexdigest()
        original = self.root / "canonical-recording-fixture"
        original.write_bytes(data)
        self.queue.publish_object(sha, data)
        first = self.publish(self.speaker_job())
        first_digest, result = self.finish(first)
        second_job = self.speaker_job(observed=1_800_000_001_000)
        second = self.publish(second_job)
        self.queue.acknowledge(first, first_digest)
        staged = self.root / "objects" / (sha + ".m4a")
        self.assertTrue(staged.exists())
        second_digest, _ = self.finish(second)
        self.queue.acknowledge(second, second_digest)
        self.assertFalse(staged.exists())
        self.assertEqual(original.read_bytes(), data)
        self.assertEqual(self.queue.result(first), result)
        self.assertEqual(
            self.queue.publish(first, encode(self.queue.request(first)))["state"],
            "acknowledged",
        )
        # A new job cannot be durably accepted in a PUT/collection/POST race.
        third = self.speaker_job(observed=1_800_000_002_000)
        with self.assertRaisesRegex(CompanionError, "media_unavailable"):
            self.publish(third)
        self.queue.publish_object(sha, data)
        self.publish(third)

    def test_ack_recovery_joins_archive_and_interrupted_collection_without_reinference(
        self,
    ):
        data = b"authored staged audio"
        sha = hashlib.sha256(data).hexdigest()
        self.queue.publish_object(sha, data)
        job_id = self.publish(self.speaker_job())
        digest, result = self.finish(job_id)
        with patch.object(
            self.queue,
            "collect_acknowledged_media",
            side_effect=OSError("authored interruption"),
        ):
            with self.assertRaises(OSError):
                self.queue.acknowledge(job_id, digest)
        self.queue.close()
        self.queue = CompanionQueue(self.root)
        self.assertEqual(self.queue.status(job_id)["state"], "acknowledged")
        staged = self.root / "objects" / (sha + ".m4a")
        unlink = Path.unlink

        def interrupted_unlink(path, *args, **kwargs):
            unlink(path, *args, **kwargs)
            if path == staged:
                raise OSError("authored interruption after unlink")

        with patch.object(Path, "unlink", interrupted_unlink):
            with self.assertRaises(OSError):
                self.queue.acknowledge(job_id, digest)
        self.queue.acknowledge(job_id, digest)
        self.assertIsNone(self.queue.claim())
        self.assertEqual(self.queue.result(job_id), result)
        self.assertEqual(
            self.queue.db.execute("SELECT count(*) FROM staged_objects").fetchone()[0],
            0,
        )

    def test_low_space_refuses_new_work_and_archive_failure_keeps_complete_result(self):
        job_id = self.publish(self.job())
        digest, result = self.finish(job_id)
        with patch(
            "retrace_companion.queue.shutil.disk_usage",
            return_value=SimpleNamespace(free=0),
        ):
            with self.assertRaisesRegex(CompanionError, "low_free_space"):
                self.publish(self.job())
            with self.assertRaisesRegex(CompanionError, "low_free_space"):
                self.queue.publish_object(hashlib.sha256(b"new").hexdigest(), b"new")
            with self.assertRaisesRegex(CompanionError, "low_free_space"):
                self.queue.acknowledge(job_id, digest)
        self.assertEqual(self.queue.status(job_id)["state"], "complete")
        self.assertEqual(self.queue.result(job_id), result)
        self.queue.acknowledge(job_id, digest)

    def test_untracked_or_changed_files_are_never_collected(self):
        data = b"authored staged audio"
        sha = hashlib.sha256(data).hexdigest()
        path = self.root / "objects" / (sha + ".m4a")
        path.write_bytes(data)
        path.chmod(0o600)
        self.queue.publish_object(sha, data)
        job_id = self.publish(self.speaker_job())
        digest, _ = self.finish(job_id)
        self.queue.acknowledge(job_id, digest)
        self.assertEqual(path.read_bytes(), data)

    def test_publication_intents_reserve_quota_after_interrupted_file_write(self):
        self.queue.max_objects = 1
        data = b"first"
        with patch(
            "retrace_companion.queue.publish_file",
            side_effect=OSError("authored write interruption"),
        ):
            with self.assertRaises(OSError):
                self.queue.publish_object(hashlib.sha256(data).hexdigest(), data)
        with self.assertRaisesRegex(CompanionError, "media_capacity"):
            self.queue.publish_object(hashlib.sha256(b"second").hexdigest(), b"second")
        self.queue.publish_object(hashlib.sha256(data).hexdigest(), data)

    def test_crash_after_durable_media_link_recovers_owned_alias_before_collection(
        self,
    ):
        data = b"authored staged audio"
        sha = hashlib.sha256(data).hexdigest()
        script = """
import hashlib, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[2])
from retrace_companion.queue import CompanionQueue
root = Path(sys.argv[1])
queue = CompanionQueue(root)
data = b'authored staged audio'
link = os.link
def crash_after_durable_link(source, destination, **options):
    link(source, destination, **options)
    directory = os.open(Path(destination).parent, os.O_RDONLY | os.O_DIRECTORY)
    os.fsync(directory)
    os.close(directory)
    os._exit(43)
os.link = crash_after_durable_link
queue.publish_object(hashlib.sha256(data).hexdigest(), data)
"""
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                script,
                str(self.root),
                str(Path(__file__).parents[2]),
            ],
            check=False,
            timeout=10,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 43, result.stderr)
        staged = self.root / "objects" / (sha + ".m4a")
        self.assertEqual(staged.stat().st_nlink, 2)
        self.queue.publish_object(sha, data)
        self.assertEqual(staged.stat().st_nlink, 1)
        self.assertEqual(list(staged.parent.glob(".publish-*")), [])
        job_id = self.publish(self.speaker_job())
        digest, retained_result = self.finish(job_id)
        self.queue.acknowledge(job_id, digest)
        self.assertFalse(staged.exists())
        self.assertEqual(self.queue.result(job_id), retained_result)

    def test_publication_recovery_preserves_unknown_links_and_unrelated_staging(self):
        data = b"authored staged audio"
        sha = hashlib.sha256(data).hexdigest()
        self.queue.publish_object(sha, data)
        staged = self.root / "objects" / (sha + ".m4a")
        unrelated = staged.parent / ".publish-abcdefgh"
        unrelated.write_bytes(data)
        unrelated.chmod(0o600)
        symlink = staged.parent / ".publish-ijklmnop"
        symlink.symlink_to(staged)
        self.queue.publish_object(sha, data)
        self.assertEqual(unrelated.read_bytes(), data)
        self.assertTrue(symlink.is_symlink())
        external = self.root / "canonical-recording-fixture"
        os.link(staged, external)
        with self.assertRaisesRegex(CompanionError, "unsafe_publication_links"):
            self.queue.publish_object(sha, data)
        self.assertEqual(external.read_bytes(), data)
        self.assertEqual(staged.stat().st_nlink, 2)

    def test_concurrent_publication_recovery_is_idempotent_without_new_allocations(
        self,
    ):
        data = b"authored staged audio"
        sha = hashlib.sha256(data).hexdigest()
        self.queue.publish_object(sha, data)
        staged = self.root / "objects" / (sha + ".m4a")
        os.link(staged, staged.parent / ".publish-abcdefgh")
        with patch(
            "retrace_companion.queue.tempfile.NamedTemporaryFile",
            side_effect=OSError("No allocation is permitted for a durable replay"),
        ):
            with ThreadPoolExecutor(max_workers=4) as workers:
                results = [
                    workers.submit(publish_file, staged, data) for _ in range(16)
                ]
                for result in results:
                    result.result(timeout=5)
        self.assertEqual(staged.stat().st_nlink, 1)
        self.assertEqual(list(staged.parent.glob(".publish-*")), [])


if __name__ == "__main__":
    unittest.main()
