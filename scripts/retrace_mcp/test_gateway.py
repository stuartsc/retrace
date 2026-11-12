"""Real HTTP boundary tests; no production stores or credentials."""

import asyncio
import json
import socket
import tempfile
import unittest
from pathlib import Path

from gateway import (
    ClientRegistry,
    NativeAuthority,
    NativeBridge,
    PrivateBearerMiddleware,
    bounded_http_protocol,
    run_native,
)


class GatewayTests(unittest.TestCase):
    def test_registry_refuses_open_permissions_and_duplicate_tokens(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "clients.json"
            path.write_text('{"clients":[]}')
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                ClientRegistry(path).load()

    def test_bridge_refuses_non_loopback_and_path_override(self):
        for url in [
            "http://example.com:9013",
            "http://127.0.0.1:9013/evil",
            "https://127.0.0.1:9013",
            "http://user:pass@127.0.0.1:9013",
        ]:
            with self.assertRaises(ValueError):
                NativeBridge(url)

    def test_offline_mutation_is_unavailable_and_never_queued(self):
        bridge = NativeBridge("http://127.0.0.1:1")
        result = bridge.command(
            "x" * 40,
            {
                "requestID": "00000000-0000-4000-8000-000000000001",
                "operation": "marker.create",
                "arguments": {},
            },
        )
        self.assertEqual(result["status"], "unavailable")
        self.assertFalse(result["queued"])

    def test_auth_rejects_duplicate_authorization_without_calling_app(self):
        called = []

        async def app(scope, receive, send):
            called.append(True)

        middleware = PrivateBearerMiddleware(app, object())
        sent = []

        async def send(message):
            sent.append(message)

        async def receive():
            return {"type": "http.request", "body": b""}

        asyncio.run(
            middleware(
                {
                    "type": "http",
                    "method": "POST",
                    "path": "/retrace-mcp",
                    "headers": [
                        (b"authorization", b"Bearer x"),
                        (b"authorization", b"Bearer y"),
                    ],
                },
                receive,
                send,
            )
        )
        self.assertEqual(sent[0]["status"], 401)
        self.assertEqual(called, [])

    def test_offline_native_authority_reports_unavailable_before_sdk(self):
        called = []

        async def app(scope, receive, send):
            called.append(True)

        middleware = PrivateBearerMiddleware(
            app, NativeAuthority(NativeBridge("http://127.0.0.1:1"))
        )
        sent = []

        async def send(message):
            sent.append(message)

        async def receive():
            return {"type": "http.request", "body": b""}

        asyncio.run(
            middleware(
                {
                    "type": "http",
                    "headers": [(b"authorization", b"Bearer " + b"x" * 40)],
                },
                receive,
                send,
            )
        )
        self.assertEqual(sent[0]["status"], 503)
        self.assertEqual(
            json.loads(sent[1]["body"]),
            {"error": "laptop_unavailable", "queued": False},
        )
        self.assertEqual(called, [])


class GatewayAdmissionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.scope = {
            "type": "http",
            "headers": [(b"authorization", b"Bearer " + b"x" * 40)],
        }
        self.sent = []
        self.app_calls = 0

    async def send(self, message):
        self.sent.append(message)

    async def receive(self):
        return {"type": "http.request", "body": b""}

    async def app(self, scope, receive, send):
        self.app_calls += 1
        await send({"type": "http.response.start", "status": 200})
        await send({"type": "http.response.body", "body": b""})

    async def test_body_trickling_has_one_total_deadline_and_releases_capacity(self):
        class Registry:
            def authenticate(self, token):
                return object()

        middleware = PrivateBearerMiddleware(
            self.app, Registry(), maximum_requests=1, input_seconds=0.05
        )

        async def trickle():
            await asyncio.sleep(0.01)
            return {"type": "http.request", "body": b"x", "more_body": True}

        await asyncio.wait_for(middleware(self.scope, trickle, self.send), 1)
        self.assertEqual(self.sent[0]["status"], 408)
        self.assertEqual(self.app_calls, 0)
        await middleware(self.scope, self.receive, self.send)
        self.assertEqual(self.sent[-2]["status"], 200)

    async def test_timed_out_auth_keeps_slot_until_blocking_authentication_finishes(
        self,
    ):
        import threading

        release = threading.Event()
        finished = asyncio.Event()
        loop = asyncio.get_running_loop()

        class Registry:
            calls = 0

            def authenticate(self, token):
                self.calls += 1
                release.wait(2)
                loop.call_soon_threadsafe(finished.set)
                return object()

        registry = Registry()
        middleware = PrivateBearerMiddleware(
            self.app, registry, maximum_requests=1, input_seconds=0.05
        )
        try:
            await middleware(self.scope, self.receive, self.send)
            self.assertEqual(self.sent[0]["status"], 408)
            await middleware(self.scope, self.receive, self.send)
            self.assertEqual(self.sent[-2]["status"], 503)
            self.assertEqual(registry.calls, 1)
        finally:
            release.set()
            await asyncio.wait_for(finished.wait(), 1)
        # Completion callbacks release admission on the event loop after the native thread ends.
        await asyncio.sleep(0.01)
        await middleware(self.scope, self.receive, self.send)
        self.assertEqual(self.sent[-2]["status"], 200)

    async def test_disconnected_sdk_dispatch_cannot_admit_competing_native_work(self):
        import threading

        entered, finished = asyncio.Event(), asyncio.Event()
        release = threading.Event()
        loop = asyncio.get_running_loop()

        class Registry:
            def authenticate(self, token):
                return object()

        def native():
            loop.call_soon_threadsafe(entered.set)
            release.wait(2)
            loop.call_soon_threadsafe(finished.set)

        async def sdk(scope, receive, send):
            await run_native(native)

        middleware = PrivateBearerMiddleware(sdk, Registry(), maximum_requests=1)
        request = asyncio.create_task(middleware(self.scope, self.receive, self.send))
        try:
            await asyncio.wait_for(entered.wait(), 1)
            request.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await request
            await middleware(self.scope, self.receive, self.send)
            self.assertEqual(self.sent[0]["status"], 503)
        finally:
            release.set()
            await asyncio.wait_for(finished.wait(), 1)
            await asyncio.sleep(0.01)
        self.assertTrue(middleware.admission.acquire(blocking=False))
        middleware.admission.release()

    async def test_registry_fifo_is_rejected_without_waiting_for_a_writer(self):
        import os

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registry"
            os.mkfifo(path, 0o600)
            with self.assertRaises(ValueError):
                ClientRegistry(path).load()


class GatewaySocketAdmissionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        import uvicorn

        self.writers = []
        self.calls = []
        self.stream_release = asyncio.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(8)
        self.port = self.listener.getsockname()[1]

        class Registry:
            def authenticate(self, token):
                return object()

        async def app(scope, receive, send):
            self.calls.append(scope["path"])
            if scope["path"] == "/stream":
                await send(
                    {"type": "http.response.start", "status": 200, "headers": []}
                )
                await send(
                    {"type": "http.response.body", "body": b"start", "more_body": True}
                )
                await self.stream_release.wait()
                await send({"type": "http.response.body", "body": b"end"})
            else:
                await send(
                    {
                        "type": "http.response.start",
                        "status": 200,
                        "headers": [(b"content-length", b"2")],
                    }
                )
                await send({"type": "http.response.body", "body": b"ok"})

        self.server = uvicorn.Server(
            uvicorn.Config(
                PrivateBearerMiddleware(app, Registry(), input_seconds=0.35),
                http=bounded_http_protocol(
                    maximum_connections=3,
                    maximum_header_bytes=1024,
                    header_seconds=0.15,
                ),
                ws="none",
                lifespan="off",
                access_log=False,
                log_level="critical",
                timeout_keep_alive=2,
            )
        )
        self.server_task = asyncio.create_task(
            self.server.serve(sockets=[self.listener])
        )
        async with asyncio.timeout(3):
            while not self.server.started:
                await asyncio.sleep(0.01)

    async def asyncTearDown(self):
        self.stream_release.set()
        for writer in self.writers:
            writer.close()
        for writer in self.writers:
            try:
                await writer.wait_closed()
            except (OSError, ConnectionError):
                pass
        self.server.should_exit = True
        await asyncio.wait_for(self.server_task, 3)
        self.listener.close()

    async def connect(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        self.writers.append(writer)
        return reader, writer

    def request(self, path="/ok", *, length=0):
        return (
            f"POST {path} HTTP/1.1\r\nHost: localhost\r\n".encode()
            + b"Authorization: Bearer "
            + b"x" * 40
            + f"\r\nContent-Length: {length}\r\n\r\n".encode()
        )

    async def response(self, reader):
        headers = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 1)
        length = next(
            int(line.split(b":", 1)[1])
            for line in headers.split(b"\r\n")
            if line.lower().startswith(b"content-length:")
        )
        body = await asyncio.wait_for(reader.readexactly(length), 1)
        return headers, body

    async def drip(self, writer):
        try:
            while True:
                writer.write(b"x")
                await writer.drain()
                await asyncio.sleep(0.025)
        except (OSError, ConnectionError):
            return

    async def test_idle_sockets_are_bounded_before_headers_and_capacity_recovers(self):
        admitted = [await self.connect() for _ in range(3)]
        rejected, _ = await self.connect()
        self.assertEqual(await asyncio.wait_for(rejected.read(), 0.5), b"")
        self.assertEqual(self.calls, [])
        for reader, _ in admitted:
            self.assertEqual(await asyncio.wait_for(reader.read(), 0.5), b"")
        reader, writer = await self.connect()
        writer.write(self.request())
        await writer.drain()
        headers, body = await self.response(reader)
        self.assertTrue(headers.startswith(b"HTTP/1.1 200"))
        self.assertEqual(body, b"ok")

    async def test_drip_headers_expire_while_another_complete_request_succeeds(self):
        slow, slow_writer = await self.connect()
        slow_writer.write(b"POST /slow HTTP/1.1\r\nHost: localhost\r\nX-Hold: ")
        await slow_writer.drain()
        dripping = asyncio.create_task(self.drip(slow_writer))
        try:
            reader, writer = await self.connect()
            writer.write(self.request())
            await writer.drain()
            self.assertEqual((await self.response(reader))[1], b"ok")
            self.assertEqual(await asyncio.wait_for(slow.read(), 0.7), b"")
            self.assertEqual(self.calls, ["/ok"])
        finally:
            dripping.cancel()
            await asyncio.gather(dripping, return_exceptions=True)

    async def test_keepalive_and_pipelined_requests_rearm_fixed_header_deadline(self):
        reader, writer = await self.connect()
        writer.write(self.request("/first") + self.request("/second"))
        await writer.drain()
        self.assertEqual((await self.response(reader))[1], b"ok")
        self.assertEqual((await self.response(reader))[1], b"ok")
        writer.write(b"POST /third HTTP/1.1\r\nHost: localhost\r\nX-Hold: ")
        await writer.drain()
        dripping = asyncio.create_task(self.drip(writer))
        try:
            self.assertEqual(await asyncio.wait_for(reader.read(), 0.7), b"")
            self.assertEqual(self.calls, ["/first", "/second"])
        finally:
            dripping.cancel()
            await asyncio.gather(dripping, return_exceptions=True)

    async def test_header_deadline_does_not_kill_streaming_response(self):
        reader, writer = await self.connect()
        writer.write(self.request("/stream"))
        await writer.drain()
        headers = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 1)
        self.assertTrue(headers.startswith(b"HTTP/1.1 200"))
        self.assertEqual(await reader.readexactly(10), b"5\r\nstart\r\n")
        await asyncio.sleep(0.35)  # More than two complete header deadlines.
        self.assertFalse(reader.at_eof())
        self.stream_release.set()
        self.assertEqual(
            await asyncio.wait_for(reader.readexactly(13), 1), b"3\r\nend\r\n0\r\n\r\n"
        )

    async def test_complete_headers_leave_body_under_existing_input_deadline(self):
        reader, writer = await self.connect()
        writer.write(self.request(length=100) + b"x")
        await writer.drain()
        await asyncio.sleep(0.2)
        self.assertFalse(reader.at_eof())
        headers = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 1)
        self.assertTrue(headers.startswith(b"HTTP/1.1 408"))
        self.assertEqual(self.calls, [])

    async def test_complete_oversized_headers_are_rejected_including_pipeline(self):
        oversized = (
            b"POST /large HTTP/1.1\r\nHost: localhost\r\nX-Large: "
            + b"x" * 2048
            + b"\r\nContent-Length: 0\r\n\r\n"
        )
        for prefix in (b"", self.request("/first")):
            reader, writer = await self.connect()
            writer.write(prefix + oversized)
            await writer.drain()
            if prefix:
                self.assertEqual((await self.response(reader))[1], b"ok")
            response = await asyncio.wait_for(reader.read(), 1)
            self.assertTrue(response.startswith(b"HTTP/1.1 400"))
        self.assertEqual(self.calls, ["/first"])


class GatewayHTTPTests(unittest.TestCase):
    def setUp(self):
        import hashlib
        import threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        self.tmp = tempfile.TemporaryDirectory()
        self.registry_file = Path(self.tmp.name) / "clients.json"
        self.token = "a-client-private-bearer-at-least-32-bytes"
        self.registry_file.write_text(
            json.dumps(
                {
                    "clients": [
                        {
                            "clientID": "fixture-client",
                            "tokenSHA256": hashlib.sha256(
                                self.token.encode()
                            ).hexdigest(),
                            "capabilities": ["markers.read"],
                        }
                    ]
                }
            )
        )
        self.registry_file.chmod(0o600)
        self.received = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["content-length"])))
                owner.received.append(
                    (body, self.headers.get("Authorization"), self.headers.get("Host"))
                )
                if body["operation"] == "capabilities.read":
                    result = {
                        "operations": [
                            {
                                "operation": "capabilities.read",
                                "capability": "manifest",
                                "mutates": False,
                                "requiresPreview": False,
                            },
                            {
                                "operation": "marker.list",
                                "capability": "markers.read",
                                "mutates": False,
                                "requiresPreview": False,
                            },
                            {
                                "operation": "unimplemented.new.feature",
                                "mutates": True,
                                "requiresPreview": False,
                            },
                        ]
                    }
                else:
                    result = {"markers": [], "nextCursor": None}
                data = json.dumps(
                    {
                        "requestID": body["requestID"],
                        "status": "succeeded",
                        "queued": False,
                        "data": result,
                    }
                ).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.native = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.native.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.native.shutdown()
        self.native.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def test_actual_mcp_list_call_and_revocation_cross_native_http(self):
        from gateway import create_app
        from starlette.testclient import TestClient

        app = create_app(
            ClientRegistry(self.registry_file),
            NativeBridge(f"http://127.0.0.1:{self.native.server_port}"),
        )
        headers = {
            "Authorization": "Bearer " + self.token,
            "Accept": "application/json, text/event-stream",
            "Host": "127.0.0.1:9012",
        }
        with TestClient(app) as client:
            result = client.post(
                "/retrace-mcp",
                headers=headers,
                json={"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
            )
            self.assertEqual(result.status_code, 200, result.text)
            names = [entry["name"] for entry in result.json()["result"]["tools"]]
            self.assertEqual(
                names, ["retrace_capabilities_read", "retrace_marker_list"]
            )
            response = client.post(
                "/retrace-mcp",
                headers=headers,
                json={
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {
                        "name": "retrace_marker_list",
                        "arguments": {
                            "request_id": "00000000-0000-4000-8000-000000000001",
                            "arguments": {"limit": 10},
                        },
                    },
                },
            )
            self.assertEqual(response.status_code, 200, response.text)
            self.assertFalse(
                response.json()["result"].get("isError", False), response.text
            )
            self.assertEqual(self.received[-1][0]["operation"], "marker.list")
            self.assertEqual(self.received[-1][1], "Bearer " + self.token)
            self.assertEqual(self.received[-1][2], "127.0.0.1:9013")
            prior = len(self.received)
            rejected = client.post(
                "/retrace-mcp",
                headers=headers,
                json={
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "retrace_marker_list",
                        "arguments": {
                            "request_id": "00000000-0000-4000-8000-000000000002",
                            "arguments": {"limit": 999999, "sql": "DROP TABLE frame"},
                        },
                    },
                },
            )
            self.assertTrue(rejected.json()["result"]["isError"])
            self.assertEqual(len(self.received), prior)
            self.registry_file.write_text('{"clients":[]}')
            denied = client.post(
                "/retrace-mcp",
                headers=headers,
                json={"jsonrpc": "2.0", "id": 4, "method": "tools/list", "params": {}},
            )
            self.assertEqual(denied.status_code, 401)
            self.assertEqual(len(self.received), prior)

    def test_browser_origin_rejected_before_native_contact(self):
        from gateway import create_app
        from starlette.testclient import TestClient

        app = create_app(
            ClientRegistry(self.registry_file),
            NativeBridge(f"http://127.0.0.1:{self.native.server_port}"),
        )
        with TestClient(app) as client:
            response = client.post(
                "/retrace-mcp",
                headers={
                    "Authorization": "Bearer " + self.token,
                    "Origin": "https://attacker.invalid",
                    "Host": "127.0.0.1:9012",
                },
                json={},
            )
            self.assertEqual(response.status_code, 401)
            self.assertEqual(self.received, [])

    def test_grant_revoked_during_manifest_never_dispatches_effect(self):
        from gateway import create_app
        from starlette.testclient import TestClient

        registry = ClientRegistry(self.registry_file)
        original = registry.authenticate
        calls = 0

        def revoke_during_manifest(token):
            nonlocal calls
            calls += 1
            return original(token) if calls <= 2 else None

        registry.authenticate = revoke_during_manifest
        app = create_app(
            registry, NativeBridge(f"http://127.0.0.1:{self.native.server_port}")
        )
        headers = {
            "Authorization": "Bearer " + self.token,
            "Accept": "application/json, text/event-stream",
            "Host": "127.0.0.1:9012",
        }
        with TestClient(app) as client:
            response = client.post(
                "/retrace-mcp",
                headers=headers,
                json={
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {
                        "name": "retrace_marker_list",
                        "arguments": {
                            "request_id": "00000000-0000-4000-8000-000000000001",
                            "arguments": {"limit": 10},
                        },
                    },
                },
            )
            self.assertEqual(response.status_code, 200)
            self.assertTrue(
                "client_grant_revoked" in response.text
                or "client grant revoked" in response.text,
                response.text,
            )
            self.assertNotIn("NoneType", response.text)
            self.assertEqual(
                [row[0]["operation"] for row in self.received], ["capabilities.read"]
            )

    def test_native_ui_authority_requires_no_primary_registry(self):
        from gateway import create_app
        from starlette.testclient import TestClient

        bridge = NativeBridge(f"http://127.0.0.1:{self.native.server_port}")
        app = create_app(NativeAuthority(bridge), bridge)
        with TestClient(app) as client:
            response = client.post(
                "/retrace-mcp",
                headers={
                    "Authorization": "Bearer " + self.token,
                    "Accept": "application/json, text/event-stream",
                    "Host": "127.0.0.1:9012",
                },
                json={"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
            )
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(
                [entry["name"] for entry in response.json()["result"]["tools"]],
                ["retrace_capabilities_read", "retrace_marker_list"],
            )
            self.assertTrue(
                all(row[1] == "Bearer " + self.token for row in self.received)
            )


if __name__ == "__main__":
    unittest.main()
