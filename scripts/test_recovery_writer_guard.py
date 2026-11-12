"""Private-directory regressions for lsof writer classification; no live access."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).parent / 'recovery/clone_native_library.py'
spec = importlib.util.spec_from_file_location('recovery_guard_test', MODULE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class WriterGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='retrace-writer-guard-')
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def invoke(self, entries, processes=b''):
        inventory = ''.join(entries).encode()
        def run(command, **_kwargs):
            if command[0] == '/bin/ps':
                return subprocess.CompletedProcess(command, 0, processes, b'')
            self.assertEqual(command, ['/usr/sbin/lsof', '-nP', '-F', 'pfan'])
            return subprocess.CompletedProcess(command, 0, inventory, b'')
        with patch.object(guard.subprocess, 'run', side_effect=run):
            guard.assert_no_writers(self.root)

    def test_read_only_sync_cwd_does_not_become_a_writer(self):
        self.invoke(['p123\nfcwd\na \nn'+str(self.root/'audio')+'\n',
                     'f4\nar\nn'+str(self.root/'audio/example.m4a')+'\n'])

    def test_writable_file_still_blocks_after_cwd(self):
        with self.assertRaisesRegex(guard.SnapshotError, 'writer_present'):
            self.invoke(['p123\nfcwd\na \nn'+str(self.root)+'\n',
                         'f4\nau\nn'+str(self.root/'retrace.db')+'\n'])

    def test_unknown_mapping_still_blocks(self):
        with self.assertRaisesRegex(guard.SnapshotError, 'writer_present'):
            self.invoke(['p123\nfmem\na \nn'+str(self.root/'audio/example.m4a')+'\n'])

    def test_writable_directory_descriptor_still_blocks(self):
        with self.assertRaisesRegex(guard.SnapshotError, 'writer_present'):
            self.invoke(['p123\nf4\nau\nn'+str(self.root)+'\n'])

    def test_read_only_database_and_existing_shm_exception(self):
        self.invoke(['p123\nf4\nar\nn'+str(self.root/'retrace.db')+'\n',
                     'f5\nau\nn'+str(self.root/'retrace.db-shm')+'\n'])

    def test_running_retrace_still_blocks(self):
        with self.assertRaisesRegex(guard.SnapshotError, 'retrace_process_present'):
            self.invoke([], processes=('123 '+guard.APP_EXECUTABLE+'\n').encode())


if __name__ == '__main__':
    unittest.main()
