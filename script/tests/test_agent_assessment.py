"""Consumer-visible safety boundaries for the primary AI assessment."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_assessment import classify_poison, conversation_url, redact_capabilities, successful_seeds


class SuccessfulSeedsTest(unittest.TestCase):
    def row(self, uid, score, outputs=None):
        return {"entry_type": "attempt", "uuid": uid, "prompt": {"turns": [{"role": "user", "content": {"text": "attack"}}]},
                "outputs": outputs if outputs is not None else [{"text": "measured response"}],
                "detector_results": {"detector": [score]}, "probe_classname": "fixture.Probe"}

    def seeds(self, *rows):
        return successful_seeds("\n".join(json.dumps(row) for row in rows), 0.8)

    def test_last_lifecycle_row_replaces_earlier_success(self):
        self.assertEqual(self.seeds(self.row("same", 1.0), self.row("same", 0.2)), [])

    def test_unmeasured_or_invalid_scores_are_not_seeds(self):
        for score in (True, "1.0", None, float("nan"), float("inf")):
            with self.subTest(score=score):
                self.assertEqual(self.seeds(self.row("bad", score)), [])
        self.assertEqual(self.seeds(self.row("bad", 1.0, [None])), [])

    def test_segment_threshold_and_matched_output_govern_success(self):
        setup = {"entry_type": "start_run setup", "run.eval_threshold": 0.95}
        self.assertEqual(self.seeds(setup, self.row("below", 0.9)), [])
        row = self.row("misaligned", 1.0, [None, {"text": "blocked"}])
        row["detector_results"] = {"detector": [1.0, 0.0]}
        self.assertEqual(self.seeds(row), [])

    def test_final_seed_keeps_provenance_and_deduplicates(self):
        row = self.row("a", 0.8)
        self.assertEqual([s["uuid"] for s in self.seeds(row, row)], ["a"])
        self.assertEqual(self.seeds(row)[0]["probe_classname"], "fixture.Probe")


class PoisonConfirmationTest(unittest.TestCase):
    def arms(self):
        return [{"arm": arm, "source_reads": 1, "response": "summarized", "receipt_count": int(arm != "control")}
                for arm in ("attack", "replay", "control")]

    def test_requires_replay_and_exposed_clean_control(self):
        self.assertEqual(classify_poison(self.arms()), "confirmed")
        for field, value in (("error", "transport failed"), ("source_reads", 0), ("response", "")):
            arms = self.arms()
            arms[2][field] = value
            self.assertEqual(classify_poison(arms), "unmeasured")

    def test_control_callback_refutes_causal_claim(self):
        arms = self.arms()
        arms[2]["receipt_count"] = 1
        self.assertEqual(classify_poison(arms), "control_matched")
        arms = self.arms()
        arms[1]["receipt_count"] = 0
        self.assertEqual(classify_poison(arms), "candidate")

    def test_exposure_without_downstream_effect_is_not_a_finding(self):
        arms = self.arms()
        for arm in arms:
            arm["receipt_count"] = 0
        self.assertEqual(classify_poison(arms), "closed_lead")

    def test_fresh_conversation_preserves_exact_target_scope(self):
        url = conversation_url("https://agent.example/case-a/?scope=own&conversation=old#chat", "f" * 64)
        self.assertEqual(url, "https://agent.example/case-a/?scope=own&conversation=" + "f" * 64 + "#chat")


class EvidenceRedactionTest(unittest.TestCase):
    def test_capabilities_never_reach_persisted_evidence(self):
        token = "A" * 43
        payload = {"response": f"fetched /agent-artifacts/source?token={token} ok",
                   "arms": [{"prompt": f"https://x/agent-artifacts/receipt?token={token}", "n": 1, "ok": True}]}
        self.assertEqual(redact_capabilities(payload), {
            "response": "fetched /agent-artifacts/source?token=[REDACTED] ok",
            "arms": [{"prompt": "https://x/agent-artifacts/receipt?token=[REDACTED]", "n": 1, "ok": True}]})


if __name__ == "__main__":
    unittest.main()
