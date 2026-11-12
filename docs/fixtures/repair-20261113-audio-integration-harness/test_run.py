import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("audio_integration_runner", HERE / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class HarnessProcessTests(unittest.TestCase):
    def test_latched_signals_restore_handlers(self):
        before = {value: signal.getsignal(value) for value in (signal.SIGINT, signal.SIGTERM)}
        with runner.ExecutionInterruption() as interruption:
            signal.raise_signal(signal.SIGTERM)
            signal.raise_signal(signal.SIGINT)
            self.assertEqual(interruption.signum, signal.SIGTERM)
        for value, handler in before.items():
            self.assertEqual(signal.getsignal(value), handler)

    def test_failure_retains_log_and_receipt_and_stops_next_command(self):
        with tempfile.TemporaryDirectory(prefix="audio-harness-failure-") as temp:
            root = Path(temp)
            commands = [[sys.executable, "-c", "print('authored failure', flush=True); raise SystemExit(7)"],
                        [sys.executable, "-c", "raise AssertionError('must not launch')"]]
            report = runner.execute_commands(commands, root, os.environ.copy(), root / "run.log", root / "receipt.json", grace=.1)
            self.assertFalse(report["completed"])
            self.assertEqual(len(report["commands"]), 1)
            self.assertEqual(report["commands"][0]["exitCode"], 7)
            self.assertTrue(report["commands"][0]["leaderReaped"])
            self.assertTrue(report["commands"][0]["groupDrained"])
            self.assertIn("authored failure", (root / "run.log").read_text())
            self.assertEqual(json.loads((root / "receipt.json").read_text()), report)

    def test_actual_sigint_and_sigterm_stop_child_and_grandchild_and_keep_interrupted_receipt(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory(prefix="audio-harness-signal-") as temp:
                root = Path(temp)
                child = root / "child.py"
                child.write_text(
                    "import json,os,signal,subprocess,sys,time\nfrom pathlib import Path\n"
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                    "grandchild=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])\n"
                    "Path(sys.argv[1]).write_text(json.dumps({'child':os.getpid(),'grandchild':grandchild.pid}))\n"
                    "print('authored children running', flush=True)\ntime.sleep(60)\n")
                driver = root / "driver.py"
                driver.write_text(
                    "import importlib.util,json,os,sys\nfrom pathlib import Path\n"
                    "spec=importlib.util.spec_from_file_location('owned_runner',sys.argv[1])\n"
                    "module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\n"
                    "root=Path(sys.argv[2])\n"
                    "commands=[[sys.executable,str(root/'child.py'),str(root/'pids.json')],"
                    "[sys.executable,'-c',\"from pathlib import Path;Path('forbidden').write_text('bad')\"]]\n"
                    "report=module.execute_commands(commands,root,os.environ.copy(),root/'run.log',root/'receipt.json',grace=.15)\n"
                    "raise SystemExit(128+report['interruptedSignal'] if report['interruptedSignal'] else 1)\n")
                process = subprocess.Popen([sys.executable, str(driver), str(HERE / "run.py"), str(root)],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                pids = {}
                try:
                    deadline = time.monotonic() + 8
                    while not (root / "pids.json").exists() and time.monotonic() < deadline and process.poll() is None:
                        time.sleep(.01)
                    self.assertTrue((root / "pids.json").exists())
                    pids = json.loads((root / "pids.json").read_text())
                    process.send_signal(signum)
                    output, error = process.communicate(timeout=8)
                    self.assertEqual(process.returncode, 128 + signum, (output, error))
                    report = json.loads((root / "receipt.json").read_text())
                    self.assertFalse(report["completed"])
                    self.assertEqual(report["interruptedSignal"], signum)
                    self.assertEqual(len(report["commands"]), 1)
                    receipt = report["commands"][0]
                    self.assertTrue(receipt["forcedKill"])
                    self.assertTrue(receipt["leaderReaped"])
                    self.assertTrue(receipt["groupDrained"], receipt)
                    self.assertEqual(receipt["remainingActivePIDs"], [])
                    self.assertFalse((root / "forbidden").exists())
                    self.assertIn("authored children running", (root / "run.log").read_text())
                    for pid in pids.values():
                        state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
                        self.assertTrue(not state.stdout.strip() or state.stdout.strip().startswith("Z"), state.stdout)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pids["child"], 0)
                finally:
                    if pids:
                        try:
                            os.killpg(pids["child"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
