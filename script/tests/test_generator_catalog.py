#!/usr/bin/env python3
"""config/probes/generators.json must describe generators that actually exist.

The file is the only source for `Target::MODEL_TYPES`, which drives both the
target wizard's generator picker and `Target`'s `model_type` inclusion
validation. Nothing regenerates it, so it drifts silently as garak changes:
an entry naming a module garak no longer ships stays selectable and fails only
when a scan tries to launch, and a class that is not a generator at all (an
exception type, an abstract base) is offered as a target type.

The catalog is allowed to be a SUBSET of what garak provides -- deciding not to
offer something is a product call. It is not allowed to name anything garak
cannot provide, which is what these tests pin.
"""

import importlib
import inspect
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "config" / "probes" / "generators.json"

# Installed into garak's package by the Dockerfiles rather than shipped by garak,
# so walking garak's own modules cannot see them.
VENDORED_MODULES = {"openrouter", "web_chatbot"}


def _garak_available():
    try:
        importlib.import_module("garak.generators.base")
    except Exception:
        return False
    return True


def _load_catalog():
    return json.loads(CATALOG.read_text())


class TestCatalogShape(unittest.TestCase):
    """Runs everywhere, including CI's bare interpreter."""

    def test_catalog_is_a_mapping_of_module_to_class_names(self):
        catalog = _load_catalog()
        self.assertIsInstance(catalog, dict)
        self.assertTrue(catalog, "generator catalog is empty")
        for module, classes in catalog.items():
            self.assertIsInstance(classes, list, f"{module} does not map to a list")
            self.assertTrue(classes, f"{module} maps to an empty list")
            for name in classes:
                self.assertIsInstance(name, str)
                self.assertFalse(
                    name.startswith("_"),
                    f"{module}.{name} is a private name and cannot be a target type",
                )


@unittest.skipUnless(_garak_available(), "garak is not importable")
class TestCatalogMatchesInstalledGarak(unittest.TestCase):
    def setUp(self):
        self.catalog = _load_catalog()
        self.base = importlib.import_module("garak.generators.base").Generator

    def test_every_catalogued_module_is_importable(self):
        """Catches the stale-entry failure: a module garak dropped."""
        for module in self.catalog:
            if module in VENDORED_MODULES:
                continue
            with self.subTest(module=module):
                try:
                    importlib.import_module(f"garak.generators.{module}")
                except ImportError as error:
                    self.fail(f"catalogued generator module {module!r} is not installed: {error}")

    def test_every_catalogued_class_is_a_concrete_generator(self):
        """Catches the wrong-kind-of-class failure: exceptions, the abstract base."""
        for module, classes in self.catalog.items():
            if module in VENDORED_MODULES:
                continue
            imported = importlib.import_module(f"garak.generators.{module}")
            for name in classes:
                with self.subTest(generator=f"{module}.{name}"):
                    obj = getattr(imported, name, None)
                    self.assertIsNotNone(obj, f"{module}.{name} does not exist")
                    self.assertTrue(inspect.isclass(obj), f"{module}.{name} is not a class")
                    self.assertTrue(
                        issubclass(obj, self.base),
                        f"{module}.{name} is not a Generator subclass",
                    )
                    self.assertIsNot(
                        obj, self.base, f"{module}.{name} is the abstract base, not a target type"
                    )


if __name__ == "__main__":
    unittest.main()
