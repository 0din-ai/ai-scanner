#!/usr/bin/env python3
"""Both container images must install the same vendored garak plugins.

`Dockerfile` (production) and `Dockerfile.dev` each copy files from
script/garak_plugins/ into garak's site-packages. A file only one of them copies
is missing at runtime in the other, and nothing says so until a scan fails:
detectors/0din.py imports its helpers at module scope, so one absent helper makes
EVERY 0din detector fail to load, while an absent generator makes only the target
types that use it unlaunchable.

Dev had been missing both vendored generators, so an OpenRouter or web-chatbot
target could not run there at all while working in production.
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "script" / "garak_plugins"
COPY_RE = re.compile(r"script/garak_plugins/([\w./-]+\.py)")


def _installed_by(dockerfile):
    return set(COPY_RE.findall((ROOT / dockerfile).read_text()))


class TestPluginInstallPaths(unittest.TestCase):
    def test_both_dockerfiles_install_the_same_files(self):
        production = _installed_by("Dockerfile")
        development = _installed_by("Dockerfile.dev")

        self.assertEqual(
            production,
            development,
            "Dockerfile and Dockerfile.dev install different vendored plugin sets",
        )

    def test_every_vendored_plugin_is_installed(self):
        """A new plugin file that no image copies is dead weight at runtime."""
        vendored = {
            str(path.relative_to(PLUGIN_DIR))
            for path in PLUGIN_DIR.rglob("*.py")
            if "__pycache__" not in path.parts
        }

        self.assertEqual(
            vendored - _installed_by("Dockerfile"),
            set(),
            "vendored plugin files are not copied into the image by Dockerfile",
        )


if __name__ == "__main__":
    unittest.main()
