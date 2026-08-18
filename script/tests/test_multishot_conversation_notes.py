#!/usr/bin/env python3
"""Multi-shot 0din probes must survive garak's write-once Attempt.prompt.

garak >= 0.15 raises TypeError("prompt cannot be changed once set") on reassignment,
which aborted the whole run for NotionTemplate, ChemicalInquiryEscalation and
HexRecipeBookCM. The conversation still has to reach the report for token accounting,
so it travels in notes instead -- and must stay out of attempt.conversations, because
the vendored 0din detectors score every assistant turn in attempt.all_outputs.
"""

import importlib
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"


def _garak_available():
    try:
        importlib.import_module("garak")
    except Exception:
        return False
    return True


def _load_local_plugin(module_name, relative_path):
    spec = importlib.util.spec_from_file_location(module_name, PLUGIN_DIR / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeGenerator:
    """Returns a distinct reply per call, in garak's List[Message] shape."""

    def __init__(self):
        self.calls = []

    def generate(self, conversation, generations_this_call=1):
        from garak.attempt import Message

        self.calls.append(conversation)
        return [Message(text=f"reply {len(self.calls)}", lang="en")]


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestMultiShotConversationNotes(unittest.TestCase):
    def setUp(self):
        from garak.attempt import Attempt, Message

        self.module = _load_local_plugin("local_0din_multishot", "probes/0din.py")
        self.probe = object.__new__(self.module.NotionTemplate)
        self.probe.generator = FakeGenerator()
        self.combined_prompt = "first ask\n\n--\n\nsecond ask"
        self.probe._prompt_data_map = {
            self.combined_prompt: ("sarin gas", ["first ask", "second ask"])
        }
        self.attempt = Attempt(
            prompt=Message(text=self.combined_prompt, lang="en"),
            probe_classname="0din.NotionTemplate",
        )

    def test_execute_attempt_does_not_reassign_the_prompt(self):
        # The regression: this raised TypeError and failed the entire scan.
        result = self.probe._execute_attempt(self.attempt)

        self.assertEqual(result.prompt.turns[-1].content.text, self.combined_prompt)

    def test_scores_one_output_per_attempt(self):
        result = self.probe._execute_attempt(self.attempt)

        # all_outputs is what the vendored 0din detectors iterate. Two turns were sent,
        # but the attempt is one attack and must present one combined output.
        self.assertEqual(len(result.all_outputs), 1)
        self.assertEqual(result.all_outputs[0].text, "reply 1\n\n--\n\nreply 2")

    def test_records_the_conversation_it_actually_sent(self):
        result = self.probe._execute_attempt(self.attempt)

        conversation = result.notes["multiturn_conversation"]
        self.assertEqual(
            [(turn.role, turn.content.text) for turn in conversation.turns],
            [
                ("user", "first ask"),
                ("assistant", "reply 1"),
                ("user", "second ask"),
                ("assistant", "reply 2"),
            ],
        )

    def test_conversation_survives_serialisation(self):
        result = self.probe._execute_attempt(self.attempt)

        turns = result.as_dict()["notes"]["multiturn_conversation"]["turns"]

        # TokenEstimator.extract_prompt_text parses exactly this shape.
        self.assertEqual([turn["role"] for turn in turns],
                         ["user", "assistant", "user", "assistant"])
        self.assertEqual(turns[0]["content"]["text"], "first ask")

    def test_single_turn_attempt_records_no_conversation(self):
        from garak.attempt import Attempt, Message

        self.probe._prompt_data_map = None
        attempt = Attempt(prompt=Message(text="only ask", lang="en"),
                          probe_classname="0din.NotionTemplate")

        result = self.probe._execute_attempt(attempt)

        self.assertEqual(len(result.all_outputs), 1)
        self.assertNotIn("multiturn_conversation", result.notes)


if __name__ == "__main__":
    unittest.main()
