"""Private bearer-authenticated transport. No SQL, shell or arbitrary path interface."""

from __future__ import annotations

import hmac
import re
import socket
import sqlite3
import threading
from contextlib import closing
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

from .contract import CompanionError, MAX_JOB, MAX_OBJECT, decode, encode, shape
from .queue import CompanionQueue


class BoundedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = False
    block_on_close = True

    def __init__(self, address, handler, maximum_connections=4):
        self.admission = threading.BoundedSemaphore(maximum_connections)
        super().__init__(address, handler)

    def process_request(self, request, address):
        if not self.admission.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.admission.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.admission.release()


def make_server(address, root, token, *, connection_seconds=30):
    if (
        not isinstance(token, str)
        or not 32 <= len(token) <= 4096
        or any(not 33 <= ord(character) <= 126 for character in token)
    ):
        raise CompanionError("transport_token_required")
    queue = CompanionQueue(root)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def setup(self):
            super().setup()
            self.connection.settimeout(connection_seconds)

            def expire():
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

            # A fixed total deadline also bounds trickled unauthenticated headers.
            self.deadline = threading.Timer(connection_seconds, expire)
            self.deadline.start()

        def finish(self):
            self.deadline.cancel()
            try:
                super().finish()
            finally:
                self.deadline.join()

        def log_message(self, *_):
            pass

        def reply(self, status, data):
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Connection", "close")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except OSError:
                # A total-deadline expiry or disconnected client cannot accept a reply.
                self.close_connection = True

        def request_body(self, maximum):
            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) != 1:
                raise CompanionError("invalid_length")
            raw = lengths[0]
            if (
                not raw.isascii()
                or not raw.isdecimal()
                or len(raw) > 10
                or int(raw) > maximum
                or self.headers.get("Transfer-Encoding")
            ):
                raise CompanionError("payload_limit")
            data = self.rfile.read(int(raw))
            if len(data) != int(raw):
                raise CompanionError("incomplete_request")
            return data

        def dispatch(self):
            self.close_connection = True
            authorizations = self.headers.get_all("Authorization", [])
            if len(authorizations) != 1 or not hmac.compare_digest(
                authorizations[0].encode("utf-8"), ("Bearer " + token).encode("utf-8")
            ):
                self.reply(401, encode({"reason": "unauthorized"}))
                return
            match = re.fullmatch(
                r"/v1/(jobs|objects|results|acks|status)/([0-9a-f]{64})", self.path
            )
            if not match:
                self.reply(404, encode({"reason": "unknown_endpoint"}))
                return
            resource, job_id = match.groups()
            try:
                # Each handler owns its own SQLite connection. Publication quotas
                # are checked under a write transaction across receiver threads.
                with closing(CompanionQueue(root)) as current:
                    if self.command == "POST" and resource == "jobs":
                        status = current.publish(job_id, self.request_body(MAX_JOB))
                        self.reply(200, encode(status))
                    elif self.command == "PUT" and resource == "objects":
                        current.publish_object(job_id, self.request_body(MAX_OBJECT))
                        self.reply(200, encode({"sha256": job_id}))
                    elif self.command == "GET" and resource == "results":
                        result = current.result(job_id)
                        self.reply(
                            200 if result else 202,
                            result or encode(current.status(job_id)),
                        )
                    elif self.command == "GET" and resource == "status":
                        self.reply(200, encode(current.status(job_id)))
                    elif self.command == "POST" and resource == "acks":
                        ack = decode(self.request_body(4096), 4096)
                        shape(ack, {"sha256"})
                        current.acknowledge(job_id, ack["sha256"])
                        self.reply(200, encode(current.status(job_id)))
                    else:
                        self.reply(405, encode({"reason": "method_not_allowed"}))
            except (CompanionError, OSError, sqlite3.Error) as error:
                self.reply(
                    409,
                    encode(
                        {
                            "reason": str(error)
                            if isinstance(error, CompanionError)
                            else "storage_unavailable"
                        }
                    ),
                )

        do_GET = dispatch
        do_POST = dispatch
        do_PUT = dispatch

    server = BoundedHTTPServer(address, Handler)
    server.companion_queue = queue
    return server
