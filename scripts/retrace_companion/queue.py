"""Durable local inbox/results/ack ledger. A single worker owns inference admission."""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import shutil
import sqlite3
import stat
import tempfile
import time
from pathlib import Path

from .contract import (
    CompanionError,
    MAX_JOB,
    MAX_OBJECT,
    MAX_RESULT,
    decode,
    digest,
    validate_job,
    validate_result,
)

MINIMUM_FREE_BYTES = 256 * 1024 * 1024


def acquire_initialization_lock(descriptor: int) -> None:
    """A stalled owner cannot retain a receiver thread beyond this bounded wait."""
    deadline = time.monotonic() + 1.0
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CompanionError("storage_unavailable") from None
            time.sleep(min(0.01, remaining))


def read_private(path: Path, limit: int) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as reader:
        if not stat.S_ISREG(os.fstat(reader.fileno()).st_mode):
            raise CompanionError("not_regular_file")
        data = reader.read(limit + 1)
    if len(data) > limit:
        raise CompanionError("payload_limit")
    return data


def publish_file(path: Path, data: bytes) -> None:
    # Replays require no new allocation. They also finish a publication whose
    # durable link survived a process exit before its temporary name was removed.
    try:
        _finish_publication(path, data)
        return
    except FileNotFoundError:
        pass
    with tempfile.NamedTemporaryFile(
        dir=path.parent, prefix=".publish-", delete=False
    ) as writer:
        temporary = Path(writer.name)
        try:
            writer.write(data)
            writer.flush()
            os.fsync(writer.fileno())
            try:
                os.link(temporary, path, follow_symlinks=False)
            except FileExistsError:
                if read_private(path, len(data)) != data:
                    raise CompanionError("publication_conflict")
            temporary.unlink(missing_ok=True)
            _finish_publication(path, data)
        finally:
            temporary.unlink(missing_ok=True)


def _finish_publication(path: Path, data: bytes) -> None:
    """Recover only this private publication's proven, same-inode staging links."""
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        directory = os.fstat(parent)
        if directory.st_uid != os.geteuid() or directory.st_mode & 0o077:
            raise CompanionError("unsafe_directory")
        descriptor = os.open(
            path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent
        )
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_size != len(data)
            ):
                raise CompanionError("unsafe_publication")
            with os.fdopen(descriptor, "rb", closefd=False) as reader:
                if reader.read(len(data) + 1) != data:
                    raise CompanionError("publication_conflict")
            identity = (info.st_dev, info.st_ino)
            if info.st_nlink > 1:
                candidates = []
                with os.scandir(parent) as entries:
                    for entry in entries:
                        # This is tempfile's reserved name shape. A sibling with
                        # matching bytes but a different inode is never ours.
                        if not re.fullmatch(r"\.publish-[a-z0-9_]{8}", entry.name):
                            continue
                        try:
                            staged = entry.stat(follow_symlinks=False)
                        except FileNotFoundError:
                            continue
                        if (staged.st_dev, staged.st_ino) == identity:
                            candidates.append(entry.name)
                # Refuse unknown links, including hardlinks outside this private
                # directory. A concurrent publisher may already have removed its
                # own staging name, so refresh both candidates and the link count.
                retained = []
                for name in candidates:
                    try:
                        staged = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    if (staged.st_dev, staged.st_ino) == identity:
                        retained.append(name)
                if os.fstat(descriptor).st_nlink > len(retained) + 1:
                    raise CompanionError("unsafe_publication_links")
                for name in retained:
                    try:
                        staged = os.stat(name, dir_fd=parent, follow_symlinks=False)
                        if (staged.st_dev, staged.st_ino) != identity:
                            continue
                        os.unlink(name, dir_fd=parent)
                    except FileNotFoundError:
                        pass  # Another retry finished the same owned cleanup.
            current = os.fstat(descriptor)
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (
                current.st_nlink != 1
                or (named.st_dev, named.st_ino) != identity
                or current.st_size != info.st_size
                or current.st_mtime_ns != info.st_mtime_ns
            ):
                raise CompanionError("unsafe_publication")
            # Both the final name and removal of temporary aliases must be
            # durable before a caller commits acknowledgement or GC eligibility.
            os.fsync(parent)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


class CompanionQueue:
    def __init__(
        self,
        root: Path,
        max_jobs=256,
        max_object_bytes=1024 * 1024 * 1024,
        max_objects=4096,
        minimum_free_bytes=MINIMUM_FREE_BYTES,
    ):
        self.root = root
        self.max_jobs = max_jobs
        self.max_object_bytes = max_object_bytes
        self.max_objects = max_objects
        self.minimum_free_bytes = minimum_free_bytes
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        for folder in (
            root,
            root / "objects",
            root / "results",
            root / "audio-results",
            root / "audio-jobs",
            root / "request-archive",
        ):
            folder.mkdir(mode=0o700, exist_ok=True)
            if folder.is_symlink() or not folder.is_dir():
                raise CompanionError("unsafe_directory")
            info = folder.stat()
            if info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise CompanionError("unsafe_directory")
        # Receiver and worker can start together against a brand-new inbox.
        # Serialize creation and journal-mode setup as well as schema migration;
        # SQLite cannot change journal mode inside the metadata transaction.
        descriptor = os.open(
            root / ".initialization.lock",
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
            0o600,
        )
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_uid != os.geteuid()
                or info.st_mode & 0o077
            ):
                raise CompanionError("unsafe_initialization_lock")
            acquire_initialization_lock(descriptor)
            self._initialize_database(root / "delivery.sqlite")
        finally:
            os.close(descriptor)

    def _initialize_database(self, path: Path) -> None:
        try:
            descriptor = os.open(
                path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
        except FileExistsError:
            pass
        else:
            os.close(descriptor)
        info = path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o077
        ):
            raise CompanionError("unsafe_database")
        self.db = sqlite3.connect(path, timeout=1, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        try:
            self.db.execute("PRAGMA synchronous=FULL")
            self.db.execute("BEGIN IMMEDIATE")
            application = self.db.execute("PRAGMA application_id").fetchone()[0]
            version = self.db.execute("PRAGMA user_version").fetchone()[0]
            empty = not self.db.execute(
                "SELECT 1 FROM sqlite_master LIMIT 1"
            ).fetchone()
            if not (
                (application == 1381253968 and version in (1, 2))
                or (application == 0 and version == 0 and empty)
            ):
                raise CompanionError("incompatible_database")
            # Do not use executescript: it implicitly commits the transaction
            # protecting the identity/version reads before running its statements.
            for statement in (
                """CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, payload BLOB NOT NULL, observed REAL NOT NULL,
                    state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, retry_after REAL NOT NULL DEFAULT 0,
                    result_digest TEXT, reason TEXT, created REAL NOT NULL)""",
                "CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(state,retry_after,observed DESC)",
                """CREATE TABLE IF NOT EXISTS job_objects(job_id TEXT NOT NULL, object_id TEXT NOT NULL,
                    PRIMARY KEY(job_id,object_id))""",
                "CREATE INDEX IF NOT EXISTS object_jobs ON job_objects(object_id,job_id)",
                """CREATE TABLE IF NOT EXISTS staged_objects(id TEXT PRIMARY KEY, byte_count INTEGER NOT NULL,
                    state TEXT NOT NULL)""",
                "CREATE INDEX IF NOT EXISTS staged_object_states ON staged_objects(state,id)",
            ):
                self.db.execute(statement)
            # V1 admitted at most 256 total jobs. Preserve all existing source
            # references before enabling collection; old untracked files are kept.
            if version == 1:
                rows = self.db.execute(
                    "SELECT id,payload FROM jobs LIMIT 257"
                ).fetchall()
                if len(rows) > 256:
                    raise CompanionError("incompatible_database")
                for row in rows:
                    job = decode(row[1], MAX_JOB)
                    self._record_object_references(row[0], job)
            self.db.execute("PRAGMA application_id=1381253968")
            self.db.execute("PRAGMA user_version=2")
            self.db.execute("COMMIT")
            self.db.execute("PRAGMA journal_mode=WAL")
        except BaseException:
            if self.db.in_transaction:
                self.db.execute("ROLLBACK")
            self.db.close()
            raise

    def close(self):
        self.db.close()

    def _ensure_space(self, additional: int) -> None:
        if shutil.disk_usage(self.root).free < self.minimum_free_bytes + additional:
            raise CompanionError("low_free_space")

    def _record_object_references(self, job_id, job):
        if job["kind"] == "speaker":
            self.db.executemany(
                "INSERT OR IGNORE INTO job_objects(job_id,object_id) VALUES(?,?)",
                ((job_id, item["sha256"]) for item in job["speaker"]["media"]),
            )

    def _request_data(self, job_id, payload):
        data = payload or read_private(
            self.root / "request-archive" / (job_id + ".json"), MAX_JOB
        )
        if hashlib.sha256(data).hexdigest() != job_id:
            raise CompanionError("request_digest")
        return data

    def publish(self, job_id, data):
        digest(job_id)
        if hashlib.sha256(data).hexdigest() != job_id:
            raise CompanionError("request_digest")
        job = decode(data, MAX_JOB)
        validate_job(job)
        self.db.execute("BEGIN IMMEDIATE")
        try:
            existing = self.db.execute(
                "SELECT payload FROM jobs WHERE id=?", (job_id,)
            ).fetchone()
            if existing:
                if self._request_data(job_id, existing[0]) != data:
                    raise CompanionError("publication_conflict")
            else:
                if (
                    self.db.execute(
                        "SELECT count(*) FROM jobs WHERE state IN ('pending','running','complete')"
                    ).fetchone()[0]
                    >= self.max_jobs
                ):
                    raise CompanionError("queue_capacity")
                self._ensure_space(len(data))
                if job["kind"] == "speaker":
                    for item in job["speaker"]["media"]:
                        path = self.root / "objects" / (item["sha256"] + ".m4a")
                        try:
                            info = path.lstat()
                        except FileNotFoundError as error:
                            raise CompanionError("media_unavailable") from error
                        if (
                            not stat.S_ISREG(info.st_mode)
                            or info.st_size != item["byteCount"]
                        ):
                            raise CompanionError("media_unavailable")
                self.db.execute(
                    "INSERT INTO jobs(id,payload,observed,state,created) VALUES(?,?,?,'pending',?)",
                    (job_id, data, job["observedAt"], time.time()),
                )
                self._record_object_references(job_id, job)
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        return self.status(job_id)

    def publish_object(self, object_id, data):
        digest(object_id)
        if (
            not 0 < len(data) <= MAX_OBJECT
            or hashlib.sha256(data).hexdigest() != object_id
        ):
            raise CompanionError("media_digest")
        destination = self.root / "objects" / (object_id + ".m4a")
        if destination.is_symlink():
            raise CompanionError("unsafe_media")
        self.db.execute("BEGIN IMMEDIATE")
        try:
            if not destination.exists():
                self._check_object_capacity(object_id, len(data))
                self._ensure_space(len(data))
            row = self.db.execute(
                "SELECT byte_count FROM staged_objects WHERE id=?", (object_id,)
            ).fetchone()
            if row and row[0] != len(data):
                raise CompanionError("publication_conflict")
            # A durable ownership intent precedes the file, so a failed write
            # cannot make an unrelated pre-existing file eligible for deletion.
            owned = not destination.exists() or row is not None
            if owned:
                self.db.execute(
                    "INSERT INTO staged_objects(id,byte_count,state) VALUES(?,?,'publishing') "
                    "ON CONFLICT(id) DO UPDATE SET state='publishing'",
                    (object_id, len(data)),
                )
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("BEGIN IMMEDIATE")
        try:
            if (
                owned
                and not self.db.execute(
                    "SELECT 1 FROM staged_objects WHERE id=?", (object_id,)
                ).fetchone()
            ):
                raise CompanionError("publication_superseded")
            publish_file(destination, data)
            self.db.execute(
                "UPDATE staged_objects SET state='ready' WHERE id=?", (object_id,)
            )
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def _check_object_capacity(self, object_id: str, size: int) -> None:
        names, total = set(), 0
        with os.scandir(self.root / "objects") as entries:
            for entry in entries:
                if len(names) >= self.max_objects:
                    raise CompanionError("media_capacity")
                names.add(entry.name)
                total += entry.stat(follow_symlinks=False).st_size
        # Ownership intents reserve capacity across the two publication commits.
        rows = self.db.execute(
            "SELECT id,byte_count FROM staged_objects WHERE state='publishing' LIMIT ?",
            (self.max_objects + 1,),
        ).fetchall()
        if len(rows) > self.max_objects:
            raise CompanionError("media_capacity")
        for row in rows:
            name = row[0] + ".m4a"
            if name not in names:
                names.add(name)
                total += row[1]
        if object_id + ".m4a" not in names:
            names.add(object_id + ".m4a")
            total += size
        if len(names) > self.max_objects or total > self.max_object_bytes:
            raise CompanionError("media_capacity")

    def recover_interrupted(self):
        # Caller holds the process lock for the sole model-owning inference process.
        self.db.execute(
            "UPDATE jobs SET state='pending',retry_after=0,reason='interrupted' WHERE state='running'"
        )

    def claim(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            row = self.db.execute(
                "SELECT id,payload FROM jobs WHERE state='pending' AND retry_after<=? ORDER BY observed DESC,id LIMIT 1",
                (time.time(),),
            ).fetchone()
            if row:
                self.db.execute(
                    "UPDATE jobs SET state='running',attempts=attempts+1 WHERE id=?",
                    (row[0],),
                )
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        return {"jobID": row[0], "request": decode(row[1], MAX_JOB)} if row else None

    def request(self, job_id):
        digest(job_id)
        row = self.db.execute(
            "SELECT payload FROM jobs WHERE id=?", (job_id,)
        ).fetchone()
        if not row:
            raise CompanionError("job_unavailable")
        return decode(self._request_data(job_id, row[0]), MAX_JOB)

    def complete(self, job_id, data):
        job = self.request(job_id)
        result = decode(data, MAX_RESULT)
        validate_result(result, job, job_id)
        state = self.status(job_id)
        if state["state"] not in {"running", "complete", "acknowledged"}:
            raise CompanionError("job_not_claimed")
        destination = self.root / "results" / (job_id + ".json")
        if not destination.exists():
            self._ensure_space(len(data))
        publish_file(destination, data)
        self.db.execute(
            "UPDATE jobs SET state=CASE WHEN state='acknowledged' THEN state ELSE 'complete' END,result_digest=?,reason=NULL WHERE id=?",
            (hashlib.sha256(data).hexdigest(), job_id),
        )

    def result(self, job_id):
        state = self.status(job_id)
        if state["state"] not in {"complete", "acknowledged"}:
            return None
        data = read_private(self.root / "results" / (job_id + ".json"), MAX_RESULT)
        if hashlib.sha256(data).hexdigest() != state["resultSHA256"]:
            raise CompanionError("result_digest")
        validate_result(decode(data, MAX_RESULT), self.request(job_id), job_id)
        return data

    def fail(self, job_id, reason):
        self.db.execute(
            "UPDATE jobs SET state='pending',retry_after=?,reason=? WHERE id=? AND state='running'",
            (time.time() + 30, reason[:128], job_id),
        )

    def status(self, job_id):
        digest(job_id)
        row = self.db.execute(
            "SELECT state,result_digest,attempts,reason FROM jobs WHERE id=?", (job_id,)
        ).fetchone()
        if not row:
            raise CompanionError("job_unavailable")
        return {
            "jobID": job_id,
            "state": row[0],
            "resultSHA256": row[1],
            "attempts": row[2],
            "reason": row[3],
        }

    def acknowledge(self, job_id, result_digest):
        digest(result_digest)
        result = self.result(job_id)
        if result is None or hashlib.sha256(result).hexdigest() != result_digest:
            raise CompanionError("acknowledgement_conflict")
        row = self.db.execute(
            "SELECT payload FROM jobs WHERE id=?", (job_id,)
        ).fetchone()
        request = self._request_data(job_id, row[0])
        archive = self.root / "request-archive" / (job_id + ".json")
        if not archive.exists():
            self._ensure_space(len(request))
        publish_file(archive, request)
        # The full request and result are durable before compacting this catalog
        # row. Retained IDs stay authoritative forever; replay never reruns work.
        self.db.execute(
            "UPDATE jobs SET state='acknowledged',payload=? WHERE id=?", (b"", job_id)
        )
        self.collect_acknowledged_media(job_id)

    def collect_acknowledged_media(self, job_id: str) -> None:
        """Remove only owned staging copies after a durable ack and no active use."""
        self.db.execute("BEGIN IMMEDIATE")
        try:
            rows = self.db.execute(
                "SELECT o.id,o.byte_count FROM staged_objects o "
                "JOIN job_objects r ON r.object_id=o.id JOIN jobs j ON j.id=r.job_id "
                "WHERE r.job_id=? AND j.state='acknowledged' AND o.state='ready' "
                "AND NOT EXISTS(SELECT 1 FROM job_objects a JOIN jobs active ON active.id=a.job_id "
                "WHERE a.object_id=o.id AND active.state!='acknowledged') LIMIT 32",
                (job_id,),
            ).fetchall()
            for row in rows:
                object_id, expected_size = row
                digest(object_id)
                path = self.root / "objects" / (object_id + ".m4a")
                try:
                    info = path.lstat()
                except FileNotFoundError:
                    pass  # Crash after unlink but before this transaction committed.
                else:
                    if (
                        not stat.S_ISREG(info.st_mode)
                        or info.st_nlink != 1
                        or info.st_uid != os.geteuid()
                        or stat.S_IMODE(info.st_mode) != 0o600
                        or info.st_size != expected_size
                    ):
                        raise CompanionError("unsafe_media")
                    data = read_private(path, MAX_OBJECT)
                    if hashlib.sha256(data).hexdigest() != object_id:
                        raise CompanionError("media_digest")
                    path.unlink()
                    directory = os.open(
                        path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                    )
                    try:
                        os.fsync(directory)
                    finally:
                        os.close(directory)
                self.db.execute("DELETE FROM staged_objects WHERE id=?", (object_id,))
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
