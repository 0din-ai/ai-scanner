#!/usr/bin/env python3
"""The probe catalog JSON must agree with each probe class's `primary_detector`.

`OdinProbeSource` reads `config/probes/0din_probes.json` and
`ProbeSyncHelpers#update_probe_attributes` writes its `"detector"` field straight
into `probe.detector_id` on every sync -- so a JSON value that disagrees with the
Python source of truth never self-heals; it re-asserts itself on every
`SyncProbesJob` run. This is what let ten probes' `"detector"` values keep reading
`"0din.MitigationBypass"` after their `primary_detector` was repointed to
`"0din.HarmfulCompliance"` (see `probes/0din.py`) -- a stale value with two live
consumers: the scan builder's probe grouping and each probe's detail page.

The set of probes on each detector is NOT uniform and must not be assumed to be:
two of the original ten (`EscalatingChemistryInquiry`, `ForensicTrainingScenario`)
were moved back to `0din.MitigationBypass` because their goals are indicator/list
answers, not procedures, and HarmfulCompliance under-scores a genuinely successful
attack against them. `getattr(probe_class, "primary_detector", ...)` below resolves
through normal Python attribute lookup, so it reports each class's EFFECTIVE
`primary_detector` -- inherited or overridden -- not a hardcoded expectation of
what every class in this file should use.
"""

import importlib
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"
CATALOG_PATH = ROOT / "config" / "probes" / "0din_probes.json"


def _garak_available():
    try:
        importlib.import_module("garak")
    except Exception:
        return False
    return True


def _load(module_name, relative_path):
    spec = importlib.util.spec_from_file_location(module_name, PLUGIN_DIR / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestProbeCatalogDetectorAgreement(unittest.TestCase):
    def setUp(self):
        self.probes_module = _load("local_0din_probes_catalog", "probes/0din.py")
        with open(CATALOG_PATH) as f:
            self.catalog = json.load(f)["probes"]

    def test_every_catalog_entrys_detector_matches_its_probe_classs_primary_detector(self):
        mismatches = []
        for name, entry in self.catalog.items():
            probe_class = getattr(self.probes_module, name, None)
            if probe_class is None:
                # Not a class this module exports under this exact name -- nothing
                # here to compare against.
                continue
            expected = getattr(probe_class, "primary_detector", None)
            actual = entry.get("detector")
            if expected != actual:
                mismatches.append((name, expected, actual))
        self.assertEqual(
            mismatches, [],
            f"catalog \"detector\" disagrees with primary_detector for: {mismatches}",
        )


if __name__ == "__main__":
    unittest.main()
