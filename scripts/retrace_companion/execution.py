"""Expiring per-attempt execution grants, enforced outside native inference.

The sender grants 120 seconds at most. Grants more than five seconds away from
receiver UTC are refused. Expiry is converted once to the receiver's monotonic
clock, so a later wall-clock change cannot extend inference. A restarted worker
revokes old grants. No grant means legacy remote-only behaviour.
"""

from __future__ import annotations

import math
import os
import signal
import subprocess
import sys
import time

from .contract import CompanionError, digest, shape

MAX_LEASE = 120
CLOCK_ALLOWANCE = 5
JOIN_ALLOWANCE = 5


def initialize(db):
    db.execute("""CREATE TABLE IF NOT EXISTS execution_grants(
        job_id TEXT PRIMARY KEY, attempt TEXT NOT NULL, deadline REAL NOT NULL,
        revoked INTEGER NOT NULL DEFAULT 0)""")
    db.execute(
        "CREATE TABLE IF NOT EXISTS execution_worker(singleton INTEGER PRIMARY KEY, heartbeat REAL NOT NULL)"
    )


def heartbeat(db):
    db.execute(
        "INSERT INTO execution_worker VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET heartbeat=excluded.heartbeat",
        (time.monotonic(),),
    )


def grant(db, job_id, value):
    digest(job_id)
    shape(value, {"attempt", "issuedAt", "seconds"})
    digest(value["attempt"])
    issued, seconds = value["issuedAt"], value["seconds"]
    if (
        type(issued) not in (float, int)
        or type(seconds) is not int
        or not math.isfinite(issued)
        or not 1 <= seconds <= MAX_LEASE
        or abs(time.time() - issued) > CLOCK_ALLOWANCE
    ):
        raise CompanionError("invalid_execution_grant")
    worker = db.execute(
        "SELECT heartbeat FROM execution_worker WHERE singleton=1"
    ).fetchone()
    if worker is None or not 0 <= time.monotonic() - worker[0] <= 5:
        raise CompanionError("lease_worker_unavailable")
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute(
            "DELETE FROM execution_grants WHERE deadline<? AND job_id NOT IN(SELECT id FROM jobs)",
            (time.monotonic(),),
        )
        if (
            db.execute("SELECT count(*) FROM execution_grants").fetchone()[0] >= 256
            and not db.execute(
                "SELECT 1 FROM execution_grants WHERE job_id=?", (job_id,)
            ).fetchone()
        ):
            raise CompanionError("execution_capacity")
        current = db.execute(
            "SELECT attempt,deadline,revoked FROM execution_grants WHERE job_id=?",
            (job_id,),
        ).fetchone()
        if current and (current[0] != value["attempt"] or current[2] == 1):
            raise CompanionError("execution_fenced")
        deadline = time.monotonic() + seconds
        db.execute(
            "INSERT INTO execution_grants VALUES(?,?,?,0) ON CONFLICT(job_id) DO UPDATE SET deadline=excluded.deadline,revoked=0",
            (job_id, value["attempt"], deadline),
        )
        answer = {
            "attempt": value["attempt"],
            "seconds": seconds,
            "joinAllowance": JOIN_ALLOWANCE,
            "clockAllowance": CLOCK_ALLOWANCE,
            "protocol": 1,
        }
        db.execute("COMMIT")
        return answer
    except BaseException:
        db.execute("ROLLBACK")
        raise


def permitted(db, job_id):
    row = db.execute(
        "SELECT deadline,revoked FROM execution_grants WHERE job_id=?", (job_id,)
    ).fetchone()
    return row is None or (not row[1] and time.monotonic() < row[0])


def revoke(db, job_id, attempt):
    digest(attempt)
    db.execute(
        "UPDATE execution_grants SET revoked=1 WHERE job_id=? AND attempt=?",
        (job_id, attempt),
    )
    row = db.execute(
        "SELECT attempt FROM execution_grants WHERE job_id=?", (job_id,)
    ).fetchone()
    if not row or row[0] != attempt:
        raise CompanionError("execution_fenced")
    state = db.execute("SELECT state FROM jobs WHERE id=?", (job_id,)).fetchone()
    # A worker restart resets "running" to "pending" before an old watchdog
    # necessarily drains decoder descendants. Neither pending state nor a free
    # direct-owner lock proves group exit. Completed publication follows the
    # supervisor's joined return; otherwise the sender must use enforced expiry.
    joined = state is None or state[0] in {"complete", "acknowledged"}
    return {"joined": joined, "attempt": attempt}


def group_alive(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def stop_and_join(process):
    # The direct Python child can exit before an ffmpeg/native descendant.
    # Ownership is released only once the entire group has left.
    group = process.pid
    try:
        os.killpg(group, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 1
    while group_alive(group) and time.monotonic() < deadline:
        process.poll()  # reap the leader while waiting for descendants
        time.sleep(0.02)
    while group_alive(group):
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            break
        process.poll()
        time.sleep(0.02)
    process.wait()


def supervised(queue, work, outlook):
    """Models live in a child so lease expiry can stop even blocked native calls."""
    from .contract import MAX_RESULT, decode
    from .queue import read_private

    job_id = work["jobID"]
    if not permitted(queue.db, job_id):
        raise CompanionError("execution_expired")
    output = queue.root / "execution-results" / (job_id + ".json")
    output.parent.mkdir(mode=0o700, exist_ok=True)
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "retrace_companion.local_job",
            "--root",
            str(queue.root),
            "--job",
            job_id,
            "--outlook",
            str(outlook),
            "--remote",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        while process.poll() is None:
            heartbeat(queue.db)
            if not permitted(queue.db, job_id):
                raise CompanionError("execution_expired")
            time.sleep(0.1)
        if process.returncode != 0 or not permitted(queue.db, job_id):
            raise CompanionError("execution_failed")
        return decode(read_private(output, MAX_RESULT), MAX_RESULT)
    finally:
        stop_and_join(process)
