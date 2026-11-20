import copy
import importlib.util
from pathlib import Path
import unittest
from unittest import mock
import tempfile
import fcntl

spec = importlib.util.spec_from_file_location("ios_device", Path(__file__).with_name("ios-device.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DeploymentChecks(unittest.TestCase):
    def snapshot(self):
        return {"version": 2, "business": {"products": [("p", "豆腐", 500)], "orders": [("o", "date", 500, 1000, 500, None, None)], "lines": []},
                "sync": {"orders": [("o", 1, 1, None)], "metadata": [("restore_after", "o"), ("next", "12345")]}}

    def test_exact_preservation(self):
        data = self.snapshot()
        module.verify_snapshots(data, copy.deepcopy(data))

    def test_lost_acknowledgement_or_cursor_fails(self):
        before = self.snapshot()
        for field in ("orders", "metadata"):
            after = copy.deepcopy(before); after["sync"][field] = []
            with self.assertRaises(RuntimeError):
                module.verify_snapshots(before, after)

    def test_business_change_fails(self):
        before = self.snapshot(); after = copy.deepcopy(before)
        after["business"]["products"] = []
        with self.assertRaises(RuntimeError):
            module.verify_snapshots(before, after)

    def test_only_known_lossless_migration_succeeds(self):
        before = self.snapshot(); before["version"] = 1; before["sync"] = None
        after = self.snapshot(); after["sync"] = {"orders": [("o", 1, 0, None)], "metadata": []}
        module.verify_snapshots(before, after)
        after["sync"]["orders"] = [("o", 1, 1, None)]
        with self.assertRaises(RuntimeError):
            module.verify_snapshots(before, after)

    def test_busy_host_refuses_before_contacting_device(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "artifacts").mkdir()
            with (root / "artifacts/.ios-device.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with mock.patch.object(module, "ROOT", root), mock.patch.object(module, "Device") as device, mock.patch("sys.argv", ["ios-device.py", "status"]):
                    with self.assertRaisesRegex(RuntimeError, "Another iPhone operation"):
                        module.main()
                    device.assert_not_called()


if __name__ == "__main__":
    unittest.main()
