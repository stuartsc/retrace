"""Real loopback HTTP transport, private SQLite, and durable crash-window replay."""

import hashlib
import fcntl
import http.client
import os
import tempfile
import threading
import socket
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from retrace_companion.contract import (
    encode,
    validate_job,
    validate_result,
    CompanionError,
)
from retrace_companion.context import propose_context
from retrace_companion.queue import (
    CompanionQueue,
    publish_file,
    acquire_initialization_lock,
)
from retrace_companion.server import make_server
from retrace_companion.worker import Processor, audio_request
import test_companion


class TransportTests(unittest.TestCase):
    def test_stalled_initialization_cannot_hold_http_shutdown_after_socket_expiry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, entered = threading.Event(), threading.Event()
            holder = {}
            token = "private-startup-test-token-" * 2

            def serve():
                server = make_server(
                    ("127.0.0.1", 0), root, token, connection_seconds=0.15
                )
                holder["server"] = server
                ready.set()
                try:
                    server.serve_forever(poll_interval=0.02)
                finally:
                    server.server_close()
                    server.companion_queue.close()

            thread = threading.Thread(target=serve)
            thread.start()
            self.assertTrue(ready.wait(5))
            server = holder["server"]
            descriptor = os.open(root / ".initialization.lock", os.O_RDWR)
            connection = socket.create_connection(
                ("127.0.0.1", server.server_port), timeout=2
            )

            def observe_wait(fd):
                entered.set()
                acquire_initialization_lock(fd)

            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch(
                    "retrace_companion.queue.acquire_initialization_lock",
                    side_effect=observe_wait,
                ):
                    request = (
                        "GET /v1/status/"
                        + "0" * 64
                        + " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer "
                        + token
                        + "\r\n\r\n"
                    )
                    connection.sendall(request.encode())
                    self.assertTrue(entered.wait(2))
                    started = time.monotonic()
                    server.shutdown()
                    thread.join(timeout=2.5)
                    self.assertFalse(
                        thread.is_alive(),
                        "A socket timeout must not leave a permanent storage-lock waiter",
                    )
                    self.assertLess(time.monotonic() - started, 2.5)
            finally:
                os.close(descriptor)
                connection.close()
                server.shutdown()
                thread.join(timeout=5)
            recovered = CompanionQueue(root)
            try:
                self.assertIsNone(recovered.claim())
            finally:
                recovered.close()

    def test_optional_context_proposal_head_is_a_uuid_and_changes_request_identity(
        self,
    ):
        fixture = test_companion.CompanionTests()
        fixture.store = "00000000-0000-0000-0000-000000000001"
        job = fixture.job()
        validate_job(job)
        original = hashlib.sha256(encode(job)).hexdigest()
        job["context"]["expectedProposalHead"] = "00000000-0000-0000-0000-000000000002"
        validate_job(job)
        self.assertNotEqual(original, hashlib.sha256(encode(job)).hexdigest())
        job["context"]["expectedProposalHead"] = "invalid"
        with self.assertRaises(CompanionError):
            validate_job(job)

    def test_slow_headers_have_total_deadline_and_cannot_block_other_client(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = threading.Event()
            holder = {}
            token = "test-token-" * 4

            def serve():
                server = make_server(
                    ("127.0.0.1", 0), Path(directory), token, connection_seconds=0.3
                )
                holder["server"] = server
                ready.set()
                try:
                    server.serve_forever(poll_interval=0.02)
                finally:
                    server.server_close()
                    server.companion_queue.close()

            thread = threading.Thread(target=serve)
            thread.start()
            self.assertTrue(ready.wait(5))
            server = holder["server"]
            slow = socket.create_connection(
                ("127.0.0.1", server.server_port), timeout=2
            )
            try:
                slow.sendall(b"GET / HTTP/1.1\r\nX-Slow: unfinished")
                connection = http.client.HTTPConnection(
                    "127.0.0.1", server.server_port, timeout=2
                )
                connection.request(
                    "GET", "/absent", headers={"Authorization": "Bearer " + token}
                )
                response = connection.getresponse()
                self.assertEqual(response.status, 404)
                response.read()
                connection.close()
                self.assertEqual(slow.recv(1), b"")
                connection = http.client.HTTPConnection(
                    "127.0.0.1", server.server_port, timeout=2
                )
                connection.putrequest("GET", "/absent")
                connection.putheader("Authorization", "Bearer " + token)
                connection.putheader("Authorization", "Bearer " + token)
                connection.endheaders()
                response = connection.getresponse()
                self.assertEqual(response.status, 401)
                response.read()
                connection.close()
            finally:
                slow.close()
                server.shutdown()
                thread.join(timeout=5)
                self.assertFalse(thread.is_alive())

    def test_authenticated_http_publication_poll_result_and_ack(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = threading.Event()
            holder = {}
            token = "private-test-token-" * 3

            def serve():
                server = make_server(("127.0.0.1", 0), root, token)
                holder["server"] = server
                ready.set()
                try:
                    server.serve_forever(poll_interval=0.05)
                finally:
                    server.server_close()
                    server.companion_queue.close()

            thread = threading.Thread(target=serve)
            thread.start()
            self.assertTrue(ready.wait(5))
            server = holder["server"]

            def request(method, path, body=b"", auth=token):
                connection = http.client.HTTPConnection(
                    "127.0.0.1", server.server_port, timeout=5
                )
                try:
                    connection.request(
                        method, path, body, {"Authorization": "Bearer " + auth}
                    )
                    response = connection.getresponse()
                    return response.status, response.read()
                finally:
                    connection.close()

            try:
                fixture = test_companion.CompanionTests()
                fixture.store = "6a6b46ea-551c-42a5-b760-a8c20a47aa9a"
                job = fixture.job()
                data = encode(job)
                job_id = hashlib.sha256(data).hexdigest()
                self.assertEqual(
                    request("POST", "/v1/jobs/" + job_id, data, auth="wrong")[0], 401
                )
                self.assertEqual(request("POST", "/v1/jobs/" + job_id, data)[0], 200)
                self.assertEqual(request("POST", "/v1/jobs/" + job_id, data)[0], 200)
                self.assertEqual(request("GET", "/v1/results/" + job_id)[0], 202)
                queue = CompanionQueue(root)
                self.assertEqual(queue.claim()["jobID"], job_id)
                result = {
                    "version": 1,
                    "jobID": job_id,
                    "kind": "context",
                    "sourceStoreID": job["sourceStoreID"],
                    "contextProposal": propose_context(
                        job, job_id, rank=lambda q, items: [0.9, 0.7, 0.1]
                    ),
                }
                result_data = encode(result)
                queue.complete(job_id, result_data)
                queue.close()
                status, fetched = request("GET", "/v1/results/" + job_id)
                self.assertEqual(status, 200)
                self.assertEqual(fetched, result_data)
                self.assertEqual(
                    request("POST", "/v1/acks/" + job_id, encode({"sha256": "0" * 64}))[
                        0
                    ],
                    409,
                )
                self.assertEqual(
                    request(
                        "POST",
                        "/v1/acks/" + job_id,
                        encode({"sha256": hashlib.sha256(fetched).hexdigest()}),
                    )[0],
                    200,
                )
                self.assertEqual(request("GET", "/v1/jobs/" + job_id)[0], 405)
            finally:
                server.shutdown()
                thread.join(timeout=5)
                self.assertFalse(thread.is_alive())

    def test_result_published_before_ledger_commit_replays_without_inference(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            queue = CompanionQueue(root)
            fixture = test_companion.CompanionTests()
            fixture.store = "6a6b46ea-551c-42a5-b760-a8c20a47aa9a"
            job = fixture.job()
            data = encode(job)
            job_id = hashlib.sha256(data).hexdigest()
            queue.publish(job_id, data)
            queue.claim()
            result = {
                "version": 1,
                "jobID": job_id,
                "kind": "context",
                "sourceStoreID": job["sourceStoreID"],
                "contextProposal": propose_context(
                    job, job_id, rank=lambda q, items: [0.9, 0.7, 0.1]
                ),
            }
            publish_file(root / "results" / (job_id + ".json"), encode(result))
            queue.recover_interrupted()
            queue.claim()
            processor = Processor(root, root / "absent-outlook")
            processor.ranker = lambda *_: self.fail("Must reuse the durable result")
            replay = processor.process(job_id, job)
            self.assertEqual(replay, result)
            queue.complete(job_id, encode(replay))
            queue.close()

    def test_speaker_exact_identity_preserves_first_pass_and_rejects_named_labels(self):
        identity = {
            "recordingGeneration": "25ba64ac-c8f0-4935-93d4-8098c732f710",
            "continuityID": "d2cf49ae-668b-4a83-81e4-dd9a0da19f0a",
            "startSample": 16000,
            "sampleCount": 32000,
            "sampleRate": 16000,
            "approximateOrigin": 1_800_000_000_000,
        }
        first_pass = "First-pass words remain available"
        job = {
            "version": 1,
            "kind": "speaker",
            "sourceStoreID": "6a6b46ea-551c-42a5-b760-a8c20a47aa9a",
            "observedAt": 1_800_000_000_000,
            "speaker": {
                "sourceIdentity": identity,
                "firstPassText": first_pass,
                "firstPassReferences": [
                    {
                        "version": 1,
                        "nativeStoreID": "6a6b46ea-551c-42a5-b760-a8c20a47aa9a",
                        "source": "microphone",
                        "rowID": 17,
                        "snapshotSHA256": "e" * 64,
                    }
                ],
                "media": [
                    {
                        "sha256": "a" * 64,
                        "byteCount": 99,
                        "mediaID": "b" * 64,
                        "offsetSamples": 0,
                        "countSamples": 32000,
                        "sourceStartSample": 16000,
                    }
                ],
            },
        }
        exact = audio_request(job)
        job["speaker"]["firstPassSourceIdentity"] = dict(
            identity, startSample=0, sampleCount=48000
        )
        validate_job(job)
        job["speaker"]["firstPassSourceIdentity"]["sampleCount"] = 16000
        with self.assertRaises(CompanionError):
            validate_job(job)
        job["speaker"]["firstPassSourceIdentity"]["sampleCount"] = 48000
        references = job["speaker"]["firstPassReferences"]
        job["speaker"]["firstPassReferences"] = []
        with self.assertRaises(CompanionError):
            validate_job(job)
        job["speaker"]["firstPassReferences"] = references * 2
        with self.assertRaises(CompanionError):
            validate_job(job)
        job["speaker"]["firstPassReferences"] = references
        references[0]["nativeStoreID"] = "00000000-0000-0000-0000-000000000001"
        with self.assertRaises(CompanionError):
            validate_job(job)
        references[0]["nativeStoreID"] = job["sourceStoreID"]
        self.assertEqual(exact["recordingGeneration"], identity["recordingGeneration"])
        self.assertEqual(exact["continuityID"], identity["continuityID"])
        self.assertEqual(exact["startSample"], 16000)
        result = {
            "version": 1,
            "jobID": "a" * 64,
            "kind": "speaker",
            "sourceStoreID": job["sourceStoreID"],
            "speakerEnrichment": {
                "sourceIdentity": identity,
                "firstPassSHA256": hashlib.sha256(first_pass.encode()).hexdigest(),
                "enhancedText": "Improved words",
                "automaticNamesCalibrated": False,
                "modelFingerprint": "c" * 64,
                "turns": [
                    {
                        "start": 0.0,
                        "end": 1.0,
                        "text": "Improved words",
                        "speakerID": "d" * 64 + ":cluster:0",
                        "speakerLabel": "Speaker 0",
                        "speakerStatus": "suggested",
                        "candidateName": "Alex",
                        "personID": "person-example",
                        "similarity": 0.99,
                    }
                ],
            },
        }
        validate_result(result, job, "a" * 64)
        self.assertEqual(job["speaker"]["firstPassText"], first_pass)
        result["speakerEnrichment"]["turns"][0]["speakerLabel"] = "Alex"
        with self.assertRaises(CompanionError):
            validate_result(result, job, "a" * 64)
        result["speakerEnrichment"]["turns"][0]["speakerLabel"] = "Speaker 0"
        result["speakerEnrichment"]["automaticNamesCalibrated"] = True
        with self.assertRaises(CompanionError):
            validate_result(result, job, "a" * 64)


if __name__ == "__main__":
    unittest.main()
