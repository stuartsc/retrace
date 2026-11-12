"""Forced APFS clones of a quiescent native library; never signals or writes source.

The command has fixed live paths and requires a separate readiness gate. Tests
exercise clone_tree only on disposable APFS trees. Success means a complete
durable-file COW copy, not an atomic volume snapshot, full content checksum,
independent physical backup or permission to install/restore an application.
Only the root regenerable retrace.db-shm cache is omitted. Root directory size
and timestamps are explicitly outside comparison; other durable metadata stays strict.
The only approved ownership exception is disclosed in the completion receipt:
the private retrace.db clone may use uid 501/gid 20 in place of uid 501/gid 0,
with mode 0644 and every other compared field unchanged.
"""
from collections import OrderedDict
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import time

SOURCE = Path('/Users/stuartbond/Library/Application Support/Retrace')
PARENT = Path('/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-09-13-progressive-recall-recovery')
DESTINATION = PARENT / 'Native library before trial'
APP_EXECUTABLE = '/Applications/Retrace.app/Contents/MacOS/Retrace'
RESERVE_BYTES = 20 * 1024**3
RECEIPTS = tuple(f'native-snapshot-{name}' for name in (
    'attempt.json', 'before.jsonl', 'after.jsonl', 'destination.jsonl',
    'complete.json', 'incomplete.json', 'completion-rejected.json'))
CRITICAL_FILES = ('retrace.db', 'retrace.db-wal', 'retrace.db-journal')
VOLATILE_CACHE = 'retrace.db-shm'
# This observed historical archive is durable data, never the active cache.
# No other suffix or dated archive is implicitly accepted.
DURABLE_SQLITE_ARCHIVES = ('retrace.db-shm.corrupt-20260723',)
ROOT_VOLATILE_FIELDS = ('size', 'mtime_ns', 'ctime_ns')
READ_DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
CREATE_FILE = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW


class SnapshotError(Exception):
    def __init__(self, code, error_number=None):
        self.code = code
        self.error_number = error_number
        super().__init__(code)


class Native:
    def __init__(self):
        self.library = ctypes.CDLL(str(Path(__file__).resolve().with_name('snapshot_native.dylib')), use_errno=True)
        declarations = {
            'snapshot_is_apfs': [ctypes.c_int],
            'snapshot_clone_regular': [ctypes.c_int, ctypes.c_int, ctypes.c_char_p],
            'snapshot_clone_symlink': [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p],
            'snapshot_copy_directory_metadata': [ctypes.c_int, ctypes.c_int],
        }
        for name, arguments in declarations.items():
            function = getattr(self.library, name)
            function.argtypes = arguments
            function.restype = ctypes.c_int

    def call(self, name, *arguments):
        result = getattr(self.library, name)(*arguments)
        if result < 0:
            raise SnapshotError('native_operation_failed', ctypes.get_errno())
        return result


@contextlib.contextmanager
def absolute_directory(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise SnapshotError('invalid_absolute_path')
    descriptor = os.open('/', READ_DIRECTORY)
    try:
        for component in path.parts[1:]:
            value = os.stat(component, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISLNK(value.st_mode):
                raise SnapshotError('path_symlink')
            following = os.open(component, READ_DIRECTORY, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = following
        yield descriptor
    finally:
        os.close(descriptor)


def identity(value):
    return value.st_dev, value.st_ino


def record(relative, value, link_target=None):
    if stat.S_ISDIR(value.st_mode):
        kind = 'directory'
    elif stat.S_ISREG(value.st_mode):
        kind = 'regular'
    elif stat.S_ISLNK(value.st_mode):
        kind = 'symlink'
    else:
        raise SnapshotError('unsupported_file_type')
    return {'path': relative, 'type': kind, 'device': value.st_dev, 'inode': value.st_ino,
            'mode': value.st_mode, 'uid': value.st_uid, 'gid': value.st_gid,
            'size': value.st_size, 'mtime_ns': value.st_mtime_ns, 'ctime_ns': value.st_ctime_ns,
            'flags': getattr(value, 'st_flags', 0), 'link_target': link_target}


def write_json(parent_fd, name, payload):
    descriptor = os.open(name, CREATE_FILE, 0o600, dir_fd=parent_fd)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(payload, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def manifest_rows(parent_fd, name):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
    with os.fdopen(descriptor) as stream:
        for line in stream:
            yield json.loads(line)


class DirectoryCache:
    """Small anchored FD cache avoids reopening each audio file's ancestors."""
    def __init__(self, root_fd, device):
        self.root_fd = root_fd
        self.device = device
        self.entries = OrderedDict()

    def get(self, relative):
        if relative == '.':
            return self.root_fd
        parts = PurePosixPath(relative).parts
        if not parts or any(part in ('', '.', '..', '/') for part in parts):
            raise SnapshotError('invalid_relative_path')
        if relative in self.entries:
            self.entries.move_to_end(relative)
            return self.entries[relative]
        parent = str(PurePosixPath(relative).parent)
        descriptor = os.open(parts[-1], READ_DIRECTORY, dir_fd=self.get(parent))
        if os.fstat(descriptor).st_dev != self.device:
            os.close(descriptor)
            raise SnapshotError('device_mismatch')
        self.entries[relative] = descriptor
        if len(self.entries) > 64:
            _, old = self.entries.popitem(last=False)
            os.close(old)
        return descriptor

    def close(self):
        for descriptor in self.entries.values():
            os.close(descriptor)
        self.entries.clear()


def cache_metadata(root_fd):
    """Inspect only the root cache entry, never open or change its contents."""
    try:
        value = os.stat(VOLATILE_CACHE, dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
        raise SnapshotError('critical_file_not_regular')
    if value.st_dev != os.fstat(root_fd).st_dev:
        raise SnapshotError('device_mismatch')
    return record(VOLATILE_CACHE, value)


def write_manifest(root_fd, parent_fd, name, device, checkpoint, *, reject_cache=False):
    summary = {'entries': 0, 'regular_files': 0, 'directories': 0, 'symlinks': 0, 'logical_file_bytes': 0}
    digest = hashlib.sha256()
    cache_start = cache_metadata(root_fd)
    if reject_cache and cache_start is not None:
        raise SnapshotError('destination_cache_present')
    descriptor = os.open(name, CREATE_FILE, 0o600, dir_fd=parent_fd)
    with os.fdopen(descriptor, 'wb') as stream:
        def append(relative, value, link_target=None):
            checkpoint()
            if value.st_dev != device:
                raise SnapshotError('device_mismatch')
            row = record(relative, value, link_target)
            raw = (json.dumps(row, sort_keys=True, ensure_ascii=True) + '\n').encode()
            stream.write(raw)
            digest.update(raw)
            summary['entries'] += 1
            summary[{'regular': 'regular_files', 'directory': 'directories', 'symlink': 'symlinks'}[row['type']]] += 1
            if row['type'] == 'regular':
                summary['logical_file_bytes'] += row['size']

        def descend(directory_fd, relative):
            append(relative, os.fstat(directory_fd))
            with os.scandir(directory_fd) as scan:
                names = sorted(entry.name for entry in scan)
            for name in names:
                if relative == '.':
                    if name.startswith('retrace.db-') and name not in (
                            *CRITICAL_FILES, VOLATILE_CACHE, *DURABLE_SQLITE_ARCHIVES):
                        raise SnapshotError('unknown_sqlite_sidecar')
                    if name == VOLATILE_CACHE:
                        # It may disappear after scandir, or be regenerated
                        # while other durable entries are inspected.
                        cache_metadata(root_fd)
                        continue
                value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                if relative == '.' and name in DURABLE_SQLITE_ARCHIVES and not stat.S_ISREG(value.st_mode):
                    raise SnapshotError('critical_file_not_regular')
                child = name if relative == '.' else relative + '/' + name
                if stat.S_ISDIR(value.st_mode):
                    child_fd = os.open(name, READ_DIRECTORY, dir_fd=directory_fd)
                    try:
                        if identity(os.fstat(child_fd)) != identity(value):
                            raise SnapshotError('source_changed')
                        descend(child_fd, child)
                    finally:
                        os.close(child_fd)
                else:
                    target = os.readlink(name, dir_fd=directory_fd) if stat.S_ISLNK(value.st_mode) else None
                    append(child, value, target)

        descend(root_fd, '.')
        stream.flush()
        os.fsync(stream.fileno())
    summary['sha256'] = digest.hexdigest()
    cache_end = cache_metadata(root_fd)
    if reject_cache and cache_end is not None:
        raise SnapshotError('destination_cache_present')
    summary['excluded_cache_at_start'] = cache_start
    summary['excluded_cache_at_end'] = cache_end
    return summary


def compare_manifests(parent_fd, first_name, second_name, *, destination=False):
    import itertools
    sentinel = object()
    ownership_remaps = []
    for first, second in itertools.zip_longest(manifest_rows(parent_fd, first_name),
                                              manifest_rows(parent_fd, second_name), fillvalue=sentinel):
        if first is sentinel or second is sentinel:
            raise SnapshotError('manifest_mismatch')
        if destination:
            if first['device'] != second['device'] or first['inode'] == second['inode']:
                raise SnapshotError('clone_identity_mismatch')
            keys = ['path', 'type', 'mode', 'uid', 'gid', 'mtime_ns', 'flags', 'link_target']
            if first['path'] == '.' and second['path'] == '.':
                keys.remove('mtime_ns')
            if first['type'] != 'directory':
                keys.append('size')
            different = [key for key in keys if first[key] != second[key]]
            if different:
                # Approved after the preserved first attempt proved this exact
                # clonefile ownership fallback and disposable fchown returned
                # EPERM. This is a disclosed private-copy policy, not an exact
                # ownership match or a permission to change the source.
                if (different == ['gid'] and first['path'] == 'retrace.db'
                        and first['type'] == 'regular'
                        and first['uid'] == second['uid'] == os.geteuid() == 501
                        and first['gid'] == 0 and second['gid'] == os.getegid() == 20
                        and first['mode'] == stat.S_IFREG | 0o644):
                    ownership_remaps.append({
                        'path': 'retrace.db', 'source_uid': 501, 'source_gid': 0,
                        'destination_uid': 501, 'destination_gid': 20, 'mode': 0o644,
                        'policy': 'approved_retrace_db_group_0_to_20'})
                else:
                    raise SnapshotError('manifest_mismatch')
        else:
            keys = set(first) | set(second)
            if first['path'] == second['path'] == '.':
                # Directory size and timestamps can change when the omitted
                # cache appears/disappears. This is an explicit comparison
                # policy, not proof of what caused those numeric changes.
                keys -= set(ROOT_VOLATILE_FIELDS)
            if any(first.get(key) != second.get(key) for key in keys):
                raise SnapshotError('source_changed')
    return ownership_remaps


def default_free_space(descriptor):
    value = os.fstatvfs(descriptor)
    return value.f_bavail * value.f_frsize


def critical_records(source_fd):
    result = {}
    for name in CRITICAL_FILES:
        try:
            value = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
        except FileNotFoundError:
            if name == 'retrace.db':
                raise SnapshotError('main_database_missing') from None
            result[name] = None
            continue
        if not stat.S_ISREG(value.st_mode):
            raise SnapshotError('critical_file_not_regular')
        result[name] = record(name, value)
    return result


def hash_recorded_file(directory_fd, name, checkpoint, expected_row=None):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    try:
        before = record(name, os.fstat(descriptor))
        if expected_row is not None and before != expected_row:
            raise SnapshotError('source_changed')
        if before['type'] != 'regular':
            raise SnapshotError('critical_file_not_regular')
        hasher = hashlib.sha256()
        while True:
            checkpoint()
            data = os.read(descriptor, 4 * 1024 * 1024)
            if not data:
                break
            hasher.update(data)
        if record(name, os.fstat(descriptor)) != before:
            raise SnapshotError('critical_file_changed')
        return hasher.hexdigest(), before
    finally:
        os.close(descriptor)


def hash_critical_files(source_fd, destination_fd, expected, checkpoint, before_hashes):
    result = {}

    for name, expected_row in expected.items():
        if expected_row is None:
            result[name] = None
            continue
        source_hash, source_row = hash_recorded_file(source_fd, name, checkpoint, expected_row)
        destination_hash, destination_row = hash_recorded_file(destination_fd, name, checkpoint)
        if source_hash != destination_hash or source_hash != before_hashes[name]:
            raise SnapshotError('critical_hash_mismatch')
        if source_row['device'] != destination_row['device'] or source_row['inode'] == destination_row['inode']:
            raise SnapshotError('clone_identity_mismatch')
        result[name] = {'source_sha256': source_hash, 'destination_sha256': destination_hash,
                        'source_before_sha256': before_hashes[name], 'source_after_sha256': source_hash,
                        'source_device': source_row['device'], 'source_inode': source_row['inode'],
                        'destination_device': destination_row['device'], 'destination_inode': destination_row['inode'],
                        'source_uid': source_row['uid'], 'source_gid': source_row['gid'],
                        'destination_uid': destination_row['uid'], 'destination_gid': destination_row['gid'],
                        'bytes': source_row['size'], 'source_mtime_ns': source_row['mtime_ns'],
                        'destination_mtime_ns': destination_row['mtime_ns']}
    return result


def clone_tree(source, destination, *, reserve_bytes=20 * 1024**3,
               quiescence=None, free_space=None, after_clone=None,
               expected_device=None, progress=None):
    source, destination = Path(source), Path(destination)
    parent = destination.parent
    if source == destination or source in destination.parents or destination in source.parents:
        raise SnapshotError('overlapping_paths')
    if destination.name in ('', '.', '..') or reserve_bytes < 0:
        raise SnapshotError('invalid_configuration')
    native = Native()
    free_space = free_space or default_free_space
    quiescence = quiescence or (lambda: assert_no_writers(source, require_retrace_absent=False))
    with absolute_directory(source) as source_fd, absolute_directory(parent) as parent_fd:
        source_stat, parent_stat = os.fstat(source_fd), os.fstat(parent_fd)
        if parent_stat.st_uid != os.getuid() or parent_stat.st_mode & 0o077:
            raise SnapshotError('parent_not_private')
        if source_stat.st_dev != parent_stat.st_dev or (
                expected_device is not None and source_stat.st_dev != expected_device):
            raise SnapshotError('device_mismatch')
        if native.call('snapshot_is_apfs', source_fd) != 1 or native.call('snapshot_is_apfs', parent_fd) != 1:
            raise SnapshotError('apfs_required')
        critical = critical_records(source_fd)
        cache_observations = {'preflight': cache_metadata(source_fd)}
        try:
            os.stat(destination.name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise SnapshotError('destination_exists')
        for name in RECEIPTS:
            try:
                os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise SnapshotError('receipt_exists')
        began = time.monotonic()
        last_check = float('-inf')
        minimum_free = free_space(parent_fd)
        initial_free = minimum_free
        cloned = 0
        stage = 'preflight'
        destination_fd = None

        def checkpoint(force=False):
            nonlocal last_check, minimum_free
            now = time.monotonic()
            if not force and now - last_check < 2:
                return
            with absolute_directory(source) as current_source, absolute_directory(parent) as current_parent:
                if identity(os.fstat(current_source)) != identity(source_stat):
                    raise SnapshotError('source_changed')
                if identity(os.fstat(current_parent)) != identity(parent_stat):
                    raise SnapshotError('parent_changed')
            if destination_fd is not None:
                if cache_metadata(destination_fd) is not None:
                    raise SnapshotError('destination_cache_present')
                try:
                    current_destination = os.stat(destination.name, dir_fd=parent_fd, follow_symlinks=False)
                except FileNotFoundError:
                    raise SnapshotError('destination_changed') from None
                if identity(current_destination) != identity(os.fstat(destination_fd)):
                    raise SnapshotError('destination_changed')
            available = free_space(parent_fd)
            minimum_free = min(minimum_free, available)
            if available < reserve_bytes:
                raise SnapshotError('free_space_reserve')
            quiescence()
            cache_metadata(source_fd)
            if progress is not None:
                progress({'stage': stage, 'cloned_entries': cloned,
                          'elapsed_seconds': round(now - began, 3), 'free_bytes': available})
            last_check = time.monotonic()

        checkpoint(force=True)
        write_json(parent_fd, 'native-snapshot-attempt.json', {
            'complete': False, 'started_at_unix_seconds': time.time(),
            'source_device': source_stat.st_dev, 'source_inode': source_stat.st_ino,
            'parent_device': parent_stat.st_dev, 'parent_inode': parent_stat.st_ino,
            'reserve_bytes': reserve_bytes, 'initial_free_bytes': initial_free,
            'ownership_policy': 'approved_retrace_db_group_0_to_20_only',
            'excluded_regenerable_cache': VOLATILE_CACHE,
            'excluded_cache_observations': cache_observations})
        source_cache = destination_cache = None
        try:
            stage = 'source_manifest_before'
            before = write_manifest(source_fd, parent_fd, 'native-snapshot-before.jsonl',
                                    source_stat.st_dev, checkpoint)
            cache_observations['before-start'] = before['excluded_cache_at_start']
            cache_observations['before-end'] = before['excluded_cache_at_end']
            if critical_records(source_fd) != critical:
                raise SnapshotError('source_changed')
            checkpoint(force=True)
            stage = 'source_critical_hashes_before'
            before_hashes = {
                name: hash_recorded_file(source_fd, name, checkpoint, row)[0]
                for name, row in critical.items() if row is not None
            }
            checkpoint(force=True)
            stage = 'forced_clone'
            os.mkdir(destination.name, 0o700, dir_fd=parent_fd)
            destination_fd = os.open(destination.name, READ_DIRECTORY, dir_fd=parent_fd)
            source_cache = DirectoryCache(source_fd, source_stat.st_dev)
            destination_cache = DirectoryCache(destination_fd, source_stat.st_dev)
            directories = []
            for row in manifest_rows(parent_fd, 'native-snapshot-before.jsonl'):
                checkpoint()
                relative = PurePosixPath(row['path'])
                if row['path'] == '.':
                    directories.append('.')
                    continue
                source_parent = source_cache.get(str(relative.parent))
                destination_parent = destination_cache.get(str(relative.parent))
                current = os.stat(relative.name, dir_fd=source_parent, follow_symlinks=False)
                link_target = os.readlink(relative.name, dir_fd=source_parent) if row['type'] == 'symlink' else None
                if record(row['path'], current, link_target) != row:
                    raise SnapshotError('source_changed')
                name = os.fsencode(relative.name)
                if row['type'] == 'directory':
                    os.mkdir(relative.name, 0o700, dir_fd=destination_parent)
                    directories.append(row['path'])
                elif row['type'] == 'regular':
                    input_fd = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_parent)
                    try:
                        if record(row['path'], os.fstat(input_fd)) != row:
                            raise SnapshotError('source_changed')
                        native.call('snapshot_clone_regular', input_fd, destination_parent, name)
                        if record(row['path'], os.fstat(input_fd)) != row:
                            raise SnapshotError('source_changed')
                    finally:
                        os.close(input_fd)
                elif row['type'] == 'symlink':
                    native.call('snapshot_clone_symlink', source_parent, name, destination_parent, name)
                else:
                    raise SnapshotError('unsupported_file_type')
                cloned += 1
                if after_clone is not None:
                    after_clone(row['path'])
            for directory in reversed(directories):
                checkpoint()
                native.call('snapshot_copy_directory_metadata', source_cache.get(directory),
                            destination_cache.get(directory))
            source_cache.close()
            destination_cache.close()
            source_cache = destination_cache = None
            os.fsync(destination_fd)
            checkpoint(force=True)
            stage = 'destination_manifest'
            copied = write_manifest(destination_fd, parent_fd, 'native-snapshot-destination.jsonl',
                                    source_stat.st_dev, checkpoint, reject_cache=True)
            stage = 'database_and_sidecar_hashes'
            hashes = hash_critical_files(source_fd, destination_fd, critical, checkpoint, before_hashes)
            stage = 'source_manifest_after'
            after = write_manifest(source_fd, parent_fd, 'native-snapshot-after.jsonl',
                                   source_stat.st_dev, checkpoint)
            cache_observations['after-start'] = after['excluded_cache_at_start']
            cache_observations['after-end'] = after['excluded_cache_at_end']
            compare_manifests(parent_fd, 'native-snapshot-before.jsonl', 'native-snapshot-after.jsonl')
            ownership_remaps = compare_manifests(parent_fd, 'native-snapshot-before.jsonl',
                                                'native-snapshot-destination.jsonl', destination=True)
            checkpoint(force=True)
            cache_observations['final'] = cache_metadata(source_fd)
            result = {'complete': True, 'scope': 'quiescent native durable-file forced APFS clone',
                      'regular_files': before['regular_files'], 'directories': before['directories'],
                      'symlinks': before['symlinks'], 'logical_file_bytes': before['logical_file_bytes'],
                      'elapsed_seconds': round(time.monotonic() - began, 3),
                      'initial_free_bytes': initial_free, 'minimum_free_bytes': minimum_free,
                      'final_free_bytes': free_space(parent_fd), 'reserve_bytes': reserve_bytes,
                      'before': before, 'after': after, 'destination': copied,
                      'critical_files': hashes,
                      'source_unchanged': False,
                      'durable_source_unchanged': True,
                      'destination_metadata_matches': False,
                      'destination_metadata_matches_approved_policy': True,
                      'excluded_cache_policy': {
                          'path': VOLATILE_CACHE, 'regenerable': True, 'copied': False,
                          'source_modified_by_helper': False},
                      'excluded_cache_observations': cache_observations,
                      'root_directory_policy': {
                          'path': '.', 'ignored_fields': list(ROOT_VOLATILE_FIELDS),
                          'identity_and_other_metadata_strict': True},
                      'exact_ownership_replication': not ownership_remaps,
                      'ownership_remaps': ownership_remaps,
                      'distinct_inodes': True, 'all_regular_files_forced_cloned': True,
                      'symlink_targets_followed': False,
                      'limits': ['Not an atomic volume snapshot or full file-content checksum.',
                                 'APFS data blocks are initially shared; future writes consume free space.',
                                 'External symlink targets are not copied.',
                                 'Same-device rollback copy does not protect against physical disk loss.',
                                 'The regenerable root retrace.db-shm cache is excluded and must be recreated by SQLite.',
                                 'Root directory size/mtime/ctime are excluded from comparison; their changes are not causally attributed.',
                                 'SQLite validation, bundle/preferences retention and install approval are separate.']}
            if ownership_remaps:
                result['limits'].append(
                    'The retrace.db clone retains the current primary group 20 instead of source group 0. '
                    'Content, owner 501, mode 0644, modification time and all other compared metadata match; '
                    'this is a functionally restorable private copy, not exact ownership replication.')
            write_json(parent_fd, 'native-snapshot-complete.json', result)
            os.fsync(parent_fd)
            return result
        except BaseException as error:
            reason = error if isinstance(error, SnapshotError) else SnapshotError('system_error', getattr(error, 'errno', None))
            # Reject a completion marker best-effort. A read-only or unavailable
            # filesystem can prevent both demotion and the failure receipt, so
            # acceptance always requires a captured zero exit as well as receipts.
            # These names were absent at preflight and are owned by this attempt.
            completion_rejection_errno = None
            try:
                os.rename('native-snapshot-complete.json', 'native-snapshot-completion-rejected.json',
                          src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
            except FileNotFoundError:
                pass
            except OSError as rejection_error:
                completion_rejection_errno = rejection_error.errno
            try:
                write_json(parent_fd, 'native-snapshot-incomplete.json', {
                    'complete': False, 'stage': stage, 'reason': reason.code,
                    'errno': reason.error_number, 'cloned_entries': cloned,
                    'completion_rejection_errno': completion_rejection_errno,
                    'excluded_cache_observations': cache_observations,
                    'elapsed_seconds': round(time.monotonic() - began, 3),
                    'partial_files_retained': True})
                os.fsync(parent_fd)
            except OSError:
                # A full/unavailable destination may prevent the failure receipt.
                # The initial attempt remains, but a stale completion marker may
                # also remain. Preserve the original failure and its nonzero exit.
                pass
            raise reason from None
        finally:
            if source_cache is not None:
                source_cache.close()
            if destination_cache is not None:
                destination_cache.close()
            if destination_fd is not None:
                os.close(destination_fd)


def assert_no_writers(source, *, require_retrace_absent=True):
    if require_retrace_absent:
        processes = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, timeout=8, check=True)
        for line in processes.stdout.decode(errors='replace').splitlines():
            pieces = line.strip().split(None, 1)
            if len(pieces) == 2 and pieces[1] == APP_EXECUTABLE:
                raise SnapshotError('retrace_process_present')
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-F', 'pfan'], capture_output=True, timeout=12)
    if result.returncode != 0:
        raise SnapshotError('writer_inventory_failed')
    root = str(Path(source))
    with absolute_directory(source) as root_fd:
        cache_metadata(root_fd)
    access = None
    for line in result.stdout.decode(errors='replace').splitlines():
        if line.startswith('f'):
            access = None
        elif line.startswith('a'):
            access = line[1:]
        elif line.startswith('n'):
            name = line[1:]
            if name == root + '/' + VOLATILE_CACHE:
                # A read-only database connection may hold a writable SHM
                # mapping. The durable DB/WAL/journal handles still fail below.
                continue
            if (name == root or name.startswith(root + '/')) and access != 'r':
                raise SnapshotError('writer_present')


def main():
    if os.environ.get('RETRACE_QUIESCENT_SNAPSHOT_READY') != '1':
        print(json.dumps({'status': 'not_run', 'reason': 'ready_gate_required'}), flush=True)
        return 2
    if len(sys.argv) != 1:
        print(json.dumps({'status': 'not_run', 'reason': 'no_path_arguments_supported'}), flush=True)
        return 2
    os.umask(0o077)
    try:
        assert_no_writers(SOURCE)
        result = clone_tree(SOURCE, DESTINATION, reserve_bytes=RESERVE_BYTES,
                            quiescence=lambda: assert_no_writers(SOURCE),
                            progress=lambda value: print(json.dumps(value, sort_keys=True), flush=True))
        print(json.dumps({'status': 'complete', 'regular_files': result['regular_files'],
                          'ownership_remaps': len(result['ownership_remaps']),
                          'elapsed_seconds': result['elapsed_seconds']}, sort_keys=True), flush=True)
        return 0
    except Exception as error:
        reason = error if isinstance(error, SnapshotError) else SnapshotError('system_error', getattr(error, 'errno', None))
        print(json.dumps({'status': 'not_complete', 'reason': reason.code,
                          'errno': reason.error_number}, sort_keys=True), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
