import unittest
from retrace_companion.repair import needs_repair, accept_repair


class RepairTests(unittest.TestCase):
    def test_third_pass_only_for_uncertainty(self):
        self.assertFalse(
            needs_repair({"text": "Clear speech", "unplacedWords": 0}, -0.3)
        )
        self.assertTrue(
            needs_repair({"text": "Faint speech", "unplacedWords": 0}, -1.2)
        )
        self.assertTrue(needs_repair({"text": "Words", "unplacedWords": 2}))

    def test_failed_or_critical_change_cannot_replace_good_text(self):
        old = {"text": "Do not pay 125 dollars", "unplacedWords": 1}
        for text in ["", "Pay 125 dollars", "Do not pay 150 dollars"]:
            self.assertFalse(
                accept_repair(old, {"text": text, "unplacedWords": 0}, -2, -0.1)
            )
        self.assertTrue(
            accept_repair(
                old,
                {"text": "Please do not pay 125 dollars", "unplacedWords": 0},
                -2,
                -0.1,
            )
        )
