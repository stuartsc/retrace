import sqlite3
import time
import unittest
from unittest.mock import patch

from retrace_companion.contract import CompanionError
from retrace_companion.execution import grant, heartbeat, initialize, permitted, revoke


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:", isolation_level=None)
        initialize(self.db)
        self.db.execute("CREATE TABLE jobs(id TEXT PRIMARY KEY,state TEXT)")
        self.job = "a" * 64
        self.attempt = "b" * 64
        heartbeat(self.db)

    def tearDown(self):
        self.db.close()

    def request(self, **changes):
        return {
            "attempt": self.attempt,
            "issuedAt": time.time(),
            "seconds": 120,
            **changes,
        }

    def test_monotonic_expiry_ignores_wall_clock_jump(self):
        with patch("retrace_companion.execution.time.monotonic", return_value=50):
            heartbeat(self.db)
            grant(self.db, self.job, self.request())
        with (
            patch("retrace_companion.execution.time.monotonic", return_value=171),
            patch("retrace_companion.execution.time.time", return_value=0),
        ):
            self.assertFalse(permitted(self.db, self.job))

    def test_attempt_fencing_and_revoked_attempt_cannot_renew(self):
        grant(self.db, self.job, self.request())
        with self.assertRaises(CompanionError):
            grant(self.db, self.job, self.request(attempt="c" * 64))
        self.assertTrue(revoke(self.db, self.job, self.attempt)["joined"])
        with self.assertRaises(CompanionError):
            grant(self.db, self.job, self.request())
        self.assertFalse(permitted(self.db, self.job))

    def test_restart_fence_can_resume_same_attempt_but_explicit_revoke_cannot(self):
        grant(self.db, self.job, self.request())
        self.db.execute("UPDATE execution_grants SET revoked=2")
        self.assertFalse(permitted(self.db, self.job))
        grant(self.db, self.job, self.request())
        self.assertTrue(permitted(self.db, self.job))
        revoke(self.db, self.job, self.attempt)
        with self.assertRaises(CompanionError):
            grant(self.db, self.job, self.request())

    def test_cancel_not_joined_until_worker_exits(self):
        grant(self.db, self.job, self.request())
        self.db.execute("INSERT INTO jobs VALUES(?,'running')", (self.job,))
        self.assertFalse(revoke(self.db, self.job, self.attempt)["joined"])
        self.db.execute("UPDATE jobs SET state='pending'")
        self.assertFalse(revoke(self.db, self.job, self.attempt)["joined"])
        self.db.execute("UPDATE jobs SET state='complete'")
        self.assertTrue(revoke(self.db, self.job, self.attempt)["joined"])

    def test_late_invalid_clock_and_unbounded_grants_rejected(self):
        for value in [
            self.request(issuedAt=time.time() - 6),
            self.request(issuedAt=float("nan")),
            self.request(seconds=121),
            self.request(seconds=True),
        ]:
            with self.assertRaises(CompanionError):
                grant(self.db, self.job, value)

    def test_join_drains_grandchild_after_direct_child_exits(self):
        import os
        import signal
        import subprocess
        import sys
        import tempfile
        from pathlib import Path
        from retrace_companion.execution import group_alive, stop_and_join

        grant(self.db, self.job, self.request())
        self.db.execute("INSERT INTO jobs VALUES(?,'running')", (self.job,))
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "grandchild"
            grandchild = (
                "import os,signal,time; from pathlib import Path; signal.signal(signal.SIGTERM, signal.SIG_IGN); Path(%r).write_text(str(os.getpid())); time.sleep(20)"
                % str(pidfile)
            )
            leader = (
                "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',%r]); time.sleep(20)"
                % grandchild
            )
            child = subprocess.Popen(
                [sys.executable, "-c", leader], start_new_session=True
            )
            try:
                deadline = time.monotonic() + 5
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(pidfile.exists())
                os.kill(child.pid, signal.SIGTERM)
                child.wait(timeout=2)
                self.assertTrue(group_alive(child.pid))
                # Reproduce recovery after the direct owner exits but while a
                # decoder descendant ignores TERM. Pending is not a join proof.
                self.db.execute("UPDATE jobs SET state='pending'")
                self.assertFalse(revoke(self.db, self.job, self.attempt)["joined"])
                stop_and_join(child)
                self.assertFalse(group_alive(child.pid))
                self.assertFalse(revoke(self.db, self.job, self.attempt)["joined"])
            finally:
                if group_alive(child.pid):
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait()

    def test_legacy_jobs_have_no_local_failover_grant(self):
        self.assertTrue(permitted(self.db, self.job))
        with self.assertRaises(CompanionError):
            revoke(self.db, self.job, self.attempt)


class ExecutionQueueTests(unittest.TestCase):
    def test_more_than_256_acknowledged_jobs_do_not_exhaust_grants(self):
        import hashlib
        import test_companion
        from retrace_companion.context import propose_context
        from retrace_companion.contract import encode

        fixture = test_companion.CompanionTests()
        fixture.setUp()
        try:
            for index in range(260):
                job = fixture.job(observed=1_800_000_000_000 + index)
                identifier = fixture.publish(job)
                heartbeat(fixture.queue.db)
                grant(
                    fixture.queue.db,
                    identifier,
                    {"attempt": "b" * 64, "issuedAt": time.time(), "seconds": 120},
                )
                self.assertEqual(fixture.queue.claim()["jobID"], identifier)
                result = encode(
                    {
                        "version": 1,
                        "jobID": identifier,
                        "kind": "context",
                        "sourceStoreID": fixture.store,
                        "contextProposal": propose_context(
                            job, identifier, rank=lambda q, texts: [0.9, 0.8, 0.1]
                        ),
                    }
                )
                fixture.queue.complete(identifier, result)
                fixture.queue.acknowledge(
                    identifier, hashlib.sha256(result).hexdigest()
                )
            self.assertEqual(
                fixture.queue.db.execute(
                    "SELECT count(*) FROM execution_grants"
                ).fetchone()[0],
                0,
            )
            self.assertEqual(
                fixture.queue.db.execute(
                    "SELECT count(*) FROM jobs WHERE state='acknowledged'"
                ).fetchone()[0],
                260,
            )
        finally:
            fixture.tearDown()


class WatchdogProcessTests(unittest.TestCase):
    def test_independent_watchdog_acknowledges_then_kills_owner_on_expiry(self):
        import os
        import select
        import signal
        import subprocess
        import sys
        import tempfile
        from pathlib import Path
        from retrace_companion.execution import stop_and_join

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "leases.sqlite"
            db = sqlite3.connect(path, isolation_level=None)
            initialize(db)
            db.execute("CREATE TABLE jobs(id TEXT PRIMARY KEY,state TEXT)")
            heartbeat(db)
            grant(
                db,
                "a" * 64,
                {"attempt": "b" * 64, "issuedAt": time.time(), "seconds": 120},
            )
            read_fd, write_fd = os.pipe()
            code = (
                "import os,subprocess,sys,time; subprocess.Popen([sys.executable,'-m','retrace_companion.lease_watchdog','--database',%r,'--job',%r,'--owner',str(os.getpid()),'--ready',str(%d)],pass_fds=(%d,),start_new_session=True); os.close(%d); time.sleep(20)"
                % (str(path), "a" * 64, write_fd, write_fd, write_fd)
            )
            owner = subprocess.Popen(
                [sys.executable, "-c", code],
                pass_fds=(write_fd,),
                start_new_session=True,
            )
            os.close(write_fd)
            try:
                self.assertTrue(select.select([read_fd], [], [], 5)[0])
                self.assertEqual(os.read(read_fd, 1), b"1")
                db.execute(
                    "UPDATE execution_grants SET deadline=?", (time.monotonic() - 1,)
                )
                self.assertEqual(owner.wait(timeout=5), -signal.SIGKILL)
            finally:
                os.close(read_fd)
                stop_and_join(owner)
                db.close()

    def test_remote_monitor_is_joined_on_orderly_return(self):
        import os
        from pathlib import Path
        import subprocess
        import sys
        import tempfile

        from retrace_companion.execution import stop_and_join

        with tempfile.TemporaryDirectory() as directory:
            db = sqlite3.connect(
                Path(directory) / "delivery.sqlite", isolation_level=None
            )
            initialize(db)
            db.execute("CREATE TABLE jobs(id TEXT PRIMARY KEY,state TEXT)")
            heartbeat(db)
            grant(
                db,
                "a" * 64,
                {"attempt": "b" * 64, "issuedAt": time.time(), "seconds": 120},
            )
            code = (
                "from pathlib import Path\n"
                "from retrace_companion.local_job import remote_monitor\n"
                "with remote_monitor(Path(%r), %r) as monitor:\n"
                "    print(monitor.pid, flush=True)\n"
                "assert monitor.returncode is not None\n"
            ) % (directory, "a" * 64)
            owner = subprocess.Popen(
                [sys.executable, "-c", code],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            try:
                output, error = owner.communicate(timeout=5)
                self.assertEqual(owner.returncode, 0, error.decode())
                watchdog_pid = int(output.strip())
                with self.assertRaises(ProcessLookupError):
                    os.kill(watchdog_pid, 0)
            finally:
                stop_and_join(owner)
                db.close()
