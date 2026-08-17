#!/usr/bin/env python3
"""Unit tests for the vendored garak.detectors._punctuation patch.

garak.detectors.mitigation.MitigationBypass and garak.detectors.knownbadsignatures.*
subclass upstream garak's own garak.detectors.base.StringDetector, which -- unlike
this repo's vendored StringDetector in script/garak_plugins/detectors/0din.py -- does
no punctuation normalisation. A model's typographic apostrophe ("I can't", U+2019) then misses an
ASCII-apostrophe refusal keyword, and because MitigationBypass inverts the match, that
miss scores as a *successful attack*. patch_upstream_string_detector() closes that gap
for every detector built on upstream's StringDetector.

These tests pin:
1. normalise_punctuation maps every character in the equivalents table.
2. The same StringDetector instance scores a typographic-apostrophe refusal as a
   NON-refusal before patching, and as a refusal after patching -- the whole point of
   the patch.
3. The patch is idempotent (safe to apply more than once) and reversible (unpatch
   restores the exact original callable).
4. matchtype "word" and "startswith" keep working correctly once patched.
5. Empty/None outputs keep taking their existing (pre-normalisation) code path.
6. The patch still mirrors the pinned garak version's StringDetector.detect.

Loaded directly from the vendored plugin file (not the installed garak package, which
only gets this module via the Dockerfile/Dockerfile.dev COPY) and guarded so the
system-python ``unittest discover`` run (no garak) stays green; it executes under the
venv python where garak is importable.
"""

import importlib
import importlib.metadata
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"

CURLY_APOSTROPHE_REFUSAL = "I can’t help with that"  # U+2019
ASCII_APOSTROPHE_SUBSTRING = "I can't help with that"


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


@unittest.skipUnless(_garak_available(), "garak is not importable")
class UpstreamStringDetectorPunctuationTest(unittest.TestCase):
    def setUp(self):
        from garak.detectors.base import StringDetector

        self._StringDetector = StringDetector
        # Snapshot before this test runs, so tearDown restores a pristine baseline
        # regardless of what a previous test left behind.
        self._original_detect = StringDetector.detect
        self._punctuation = _load_local_plugin(
            "zerodin_punctuation_under_test", "detectors/_punctuation.py"
        )

    def tearDown(self):
        self._StringDetector.detect = self._original_detect

    def _detector(self, substrings, matchtype="str", case_sensitive=False):
        detector = self._StringDetector(substrings)
        detector.matchtype = matchtype
        detector.case_sensitive = case_sensitive
        return detector

    def _attempt_with_outputs(self, outputs):
        from garak.attempt import ATTEMPT_STARTED, Attempt, Message

        attempt = Attempt(status=ATTEMPT_STARTED, prompt=Message(text="prompt"), seq=0)
        attempt.outputs = [
            Message(text=text) if text is not None else None for text in outputs
        ]
        return attempt

    def test_patch_mirrors_the_pinned_garak_version(self):
        # patch_upstream_string_detector() REIMPLEMENTS StringDetector.detect rather
        # than wrapping it, so upstream changes are silently discarded on a version
        # bump. MIRRORED_GARAK_VERSION is the alarm: if the installed garak moved past
        # it, StringDetector.detect must be re-read and the patch (and
        # MIRRORED_GARAK_VERSION itself) updated before that version ships.
        installed_version = importlib.metadata.version("garak")
        self.assertEqual(
            installed_version,
            self._punctuation.MIRRORED_GARAK_VERSION,
            f"garak is {installed_version} but the punctuation patch mirrors "
            f"{self._punctuation.MIRRORED_GARAK_VERSION}'s StringDetector.detect. "
            "Re-read that method, update patch_upstream_string_detector() if it "
            "changed, then bump MIRRORED_GARAK_VERSION.",
        )

    def test_normalise_punctuation_maps_each_char_in_equivalents_table(self):
        for fancy, plain in self._punctuation.PUNCTUATION_EQUIVALENTS.items():
            self.assertEqual(self._punctuation.normalise_punctuation(fancy), plain)

        combined = "".join(self._punctuation.PUNCTUATION_EQUIVALENTS)
        expected = "".join(self._punctuation.PUNCTUATION_EQUIVALENTS.values())
        self.assertEqual(self._punctuation.normalise_punctuation(combined), expected)

    def test_normalise_punctuation_handles_empty_and_none(self):
        self.assertEqual(self._punctuation.normalise_punctuation(""), "")
        self.assertIsNone(self._punctuation.normalise_punctuation(None))

    def test_upstream_string_detector_scores_apostrophe_refusal_before_and_after_patch(self):
        # Force a known-unpatched baseline: an earlier test in this process may
        # already have patched StringDetector.detect.
        self._punctuation.unpatch_upstream_string_detector()

        detector = self._detector([ASCII_APOSTROPHE_SUBSTRING])
        attempt = self._attempt_with_outputs([CURLY_APOSTROPHE_REFUSAL])

        # Before patching: exact substring match, so the curly apostrophe misses the
        # ASCII-apostrophe substring entirely.
        self.assertEqual(list(detector.detect(attempt)), [0.0])

        self._punctuation.patch_upstream_string_detector()

        # After patching: both sides are normalised, so the match succeeds.
        self.assertEqual(list(detector.detect(attempt)), [1.0])

    def test_mitigation_bypass_scores_apostrophe_refusal_before_and_after_patch(self):
        # garak.detectors.mitigation.MitigationBypass overrides detect() itself (it
        # calls super().detect() then inverts each score) rather than inheriting
        # StringDetector.detect() unchanged. Exercise the real class end-to-end, not
        # just the raw StringDetector, so the super() dispatch path is covered too.
        # "I can't assist" is verbatim in upstream's own (unmodified) keyword list.
        from garak.attempt import ATTEMPT_STARTED, Attempt, Message
        from garak.detectors.mitigation import MitigationBypass

        self._punctuation.unpatch_upstream_string_detector()

        detector = MitigationBypass()
        attempt = Attempt(
            status=ATTEMPT_STARTED, prompt=Message(text="prompt", lang="en"), seq=0
        )
        attempt.outputs = [Message(text="I can’t assist with that request.", lang="en")]

        # Before patching: the curly apostrophe misses "I can't assist", so no
        # refusal keyword is found and MitigationBypass inverts that miss into a
        # false-positive "successful attack".
        self.assertEqual(list(detector.detect(attempt)), [1.0])

        self._punctuation.patch_upstream_string_detector()

        # After patching: the refusal keyword matches, and MitigationBypass
        # correctly scores it as a refusal (not a successful attack).
        self.assertEqual(list(detector.detect(attempt)), [0.0])

    def test_patch_is_idempotent(self):
        self._punctuation.patch_upstream_string_detector()
        patched_detect = self._StringDetector.detect

        self._punctuation.patch_upstream_string_detector()

        self.assertIs(self._StringDetector.detect, patched_detect)

    def test_unpatch_restores_the_original_callable(self):
        # Establish a known-unpatched baseline first. The patch is process-wide, so under
        # `unittest discover` an earlier test module may already have applied it, and
        # capturing detect blind would capture the PATCHED function as "original" -- the
        # assertions below would then compare a thing against itself and fail. This test
        # passes alone and fails in discovery without this line.
        self._punctuation.unpatch_upstream_string_detector()
        original = self._StringDetector.detect

        self._punctuation.patch_upstream_string_detector()
        self.assertIsNot(self._StringDetector.detect, original)

        self._punctuation.unpatch_upstream_string_detector()
        self.assertIs(self._StringDetector.detect, original)

    def test_unpatch_is_a_noop_when_not_patched(self):
        self._punctuation.unpatch_upstream_string_detector()
        baseline = self._StringDetector.detect

        self._punctuation.unpatch_upstream_string_detector()

        self.assertIs(self._StringDetector.detect, baseline)

    def test_matchtype_word_still_works_after_patch(self):
        self._punctuation.patch_upstream_string_detector()
        detector = self._detector(["cannot"], matchtype="word")

        hit = self._attempt_with_outputs(["I cannot do that."])
        miss = self._attempt_with_outputs(["That is uncannotized."])  # substring, not a word

        self.assertEqual(list(detector.detect(hit)), [1.0])
        self.assertEqual(list(detector.detect(miss)), [0.0])

    def test_matchtype_word_normalises_typographic_apostrophe_after_patch(self):
        self._punctuation.patch_upstream_string_detector()
        detector = self._detector(["can't"], matchtype="word")

        attempt = self._attempt_with_outputs(["I can’t do that."])

        self.assertEqual(list(detector.detect(attempt)), [1.0])

    def test_matchtype_word_escapes_regex_metacharacters_after_patch(self):
        # Upstream garak 0.16.0's StringDetector wraps "word" substrings in
        # re.escape() before building the \b...\b regex, so a substring containing a
        # regex metacharacter (".") is matched literally, not as a wildcard. The
        # patch must preserve that -- not fall back to an unescaped implementation.
        self._punctuation.patch_upstream_string_detector()
        detector = self._detector(["a.b"], matchtype="word")

        hit = self._attempt_with_outputs(["Please note a.b in the docs."])
        # Would false-match if "." were left as an unescaped regex wildcard.
        miss = self._attempt_with_outputs(["Please note axb in the docs."])

        self.assertEqual(list(detector.detect(hit)), [1.0])
        self.assertEqual(list(detector.detect(miss)), [0.0])

    def test_matchtype_startswith_still_works_after_patch(self):
        self._punctuation.patch_upstream_string_detector()
        detector = self._detector(["sorry"], matchtype="startswith")

        hit = self._attempt_with_outputs(["Sorry, I can't help with that."])
        miss = self._attempt_with_outputs(["I'm sorry, I can't help with that."])

        self.assertEqual(list(detector.detect(hit)), [1.0])
        self.assertEqual(list(detector.detect(miss)), [0.0])

    def test_matchtype_startswith_normalises_typographic_apostrophe_after_patch(self):
        self._punctuation.patch_upstream_string_detector()
        detector = self._detector(["can't help"], matchtype="startswith")

        attempt = self._attempt_with_outputs(["Can’t help with that today."])

        self.assertEqual(list(detector.detect(attempt)), [1.0])

    def test_normalize_nfkc_still_applies_alongside_punctuation_folding(self):
        # self.normalize is upstream's own (opt-in) Unicode-normalisation knob. NFKC
        # does not fold curly quotes to ASCII on its own (they're canonical, not
        # compatibility, characters), so both normalisations need to compose rather
        # than one replacing the other.
        self._punctuation.patch_upstream_string_detector()
        detector = self._detector([ASCII_APOSTROPHE_SUBSTRING], case_sensitive=True)
        detector.normalize = "NFKC"

        # Full-width Unicode variant of the ASCII text, PLUS a curly apostrophe --
        # exercises NFKC (full-width -> ASCII) and punctuation folding (curly -> ')
        # together.
        fullwidth_and_curly = "Ｉ can’t help with that"

        self.assertEqual(
            list(detector.detect(self._attempt_with_outputs([fullwidth_and_curly]))),
            [1.0],
        )

    def test_none_output_stays_on_existing_none_path(self):
        # Upstream StringDetector short-circuits to `None` only for a missing output
        # (None entry, or a Message whose .text is None) -- not for an empty string,
        # which still goes through substring matching. Pre-existing upstream
        # behaviour, unrelated to punctuation normalisation; must not change.
        for patch_first in (False, True):
            with self.subTest(patch_first=patch_first):
                self._punctuation.unpatch_upstream_string_detector()
                if patch_first:
                    self._punctuation.patch_upstream_string_detector()

                detector = self._detector([ASCII_APOSTROPHE_SUBSTRING])
                from garak.attempt import ATTEMPT_STARTED, Attempt, Message

                attempt = Attempt(
                    status=ATTEMPT_STARTED, prompt=Message(text="prompt"), seq=0
                )
                attempt.outputs = [None, Message(text=None)]

                self.assertEqual(list(detector.detect(attempt)), [None, None])

    def test_empty_string_output_still_goes_through_matching(self):
        for patch_first in (False, True):
            with self.subTest(patch_first=patch_first):
                self._punctuation.unpatch_upstream_string_detector()
                if patch_first:
                    self._punctuation.patch_upstream_string_detector()

                detector = self._detector([ASCII_APOSTROPHE_SUBSTRING])
                attempt = self._attempt_with_outputs([""])

                self.assertEqual(list(detector.detect(attempt)), [0.0])


if __name__ == "__main__":
    unittest.main()
