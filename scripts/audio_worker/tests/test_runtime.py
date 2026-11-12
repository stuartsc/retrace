"""Real Torch initialization can be shared by sequential context and audio jobs."""

import importlib.util
import subprocess
import sys
import unittest


class RuntimeTests(unittest.TestCase):
    @unittest.skipIf(
        importlib.util.find_spec("torch") is None,
        "Torch is not installed in this test environment",
    )
    def test_repeated_configuration_after_native_work_does_not_reset_interop(self):
        code = """
from audio_worker.runtime import configure_torch_runtime
configure_torch_runtime()
import torch
assert torch.ones((2, 2)).sum().item() == 4
configure_torch_runtime()
assert torch.get_num_threads() == 2
assert torch.get_num_interop_threads() == 1
"""
        result = subprocess.run(
            [sys.executable, "-c", code], capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stderr)
