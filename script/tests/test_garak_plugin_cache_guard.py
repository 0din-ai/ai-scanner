import json
import os
import sys
import types
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

_script_dir = str(Path(__file__).resolve().parent.parent)
if _script_dir not in sys.path:
    sys.path.insert(0, _script_dir)

import garak_plugin_cache_guard  # noqa: E402


class TestGarakPluginCacheGuard(unittest.TestCase):
    def setUp(self):
        self.original_garak = sys.modules.get('garak')
        self.original_garak_plugins = sys.modules.get('garak._plugins')
        self.tempdir = TemporaryDirectory()
        self.cache_path = Path(self.tempdir.name) / 'plugin_cache.json'
        self.cache_path.write_text('{"probes": {', encoding='utf-8')
        cache_path = self.cache_path

        class FakePluginCache:
            _plugin_cache_dict = None
            build_calls = 0
            load_calls = 0
            build_during_load = False

            def __init__(self):
                self._user_plugin_cache_filename = str(cache_path)
                type(self)._plugin_cache_dict = self._load_plugin_cache()

            def _load_plugin_cache(self):
                type(self).load_calls += 1
                if type(self).build_during_load and type(self).load_calls == 1:
                    self._build_plugin_cache()
                    return {'probes': {'0din.Example': {}}, 'build_calls': type(self).build_calls}
                if type(self).load_calls == 1:
                    raise json.JSONDecodeError('Expecting delimiter', '{', 1)
                return {'probes': {'0din.Example': {}}, 'build_calls': type(self).build_calls}

            def _build_plugin_cache(self):
                type(self).build_calls += 1
                cache_path.write_text('{"probes": {"0din.Example": {}}}', encoding='utf-8')

        self.fake_plugin_cache = FakePluginCache
        garak = types.ModuleType('garak')
        garak.__path__ = []
        plugins = types.ModuleType('garak._plugins')
        setattr(plugins, 'PluginCache', FakePluginCache)
        setattr(garak, '_plugins', plugins)
        sys.modules['garak'] = garak
        sys.modules['garak._plugins'] = plugins

    def tearDown(self):
        self.tempdir.cleanup()
        if self.original_garak is None:
            sys.modules.pop('garak', None)
        else:
            sys.modules['garak'] = self.original_garak

        if self.original_garak_plugins is None:
            sys.modules.pop('garak._plugins', None)
        else:
            sys.modules['garak._plugins'] = self.original_garak_plugins

    def test_guard_rebuilds_corrupt_plugin_cache_and_retries_load(self):
        garak_plugin_cache_guard.install_plugin_cache_guard()

        cache = self.fake_plugin_cache()

        self.assertEqual({'probes': {'0din.Example': {}}, 'build_calls': 1}, cache._plugin_cache_dict)
        self.assertEqual(1, self.fake_plugin_cache.build_calls)
        self.assertEqual(2, self.fake_plugin_cache.load_calls)
        self.assertEqual('{"probes": {"0din.Example": {}}}', self.cache_path.read_text(encoding='utf-8'))

    def test_guard_installation_is_idempotent(self):
        garak_plugin_cache_guard.install_plugin_cache_guard()
        first_load = self.fake_plugin_cache._load_plugin_cache
        first_build = self.fake_plugin_cache._build_plugin_cache

        garak_plugin_cache_guard.install_plugin_cache_guard()

        self.assertIs(first_load, self.fake_plugin_cache._load_plugin_cache)
        self.assertIs(first_build, self.fake_plugin_cache._build_plugin_cache)

    def test_guard_allows_load_path_to_build_cache_while_lock_is_held(self):
        self.fake_plugin_cache.build_during_load = True
        garak_plugin_cache_guard.install_plugin_cache_guard()

        cache = self.fake_plugin_cache()

        self.assertEqual({'probes': {'0din.Example': {}}, 'build_calls': 1}, cache._plugin_cache_dict)
        self.assertEqual(1, self.fake_plugin_cache.build_calls)
        self.assertEqual(1, self.fake_plugin_cache.load_calls)

    def test_lock_file_open_does_not_truncate_existing_file(self):
        lock_path = Path(self.tempdir.name) / 'existing.lock'
        lock_path.write_text('do-not-truncate', encoding='utf-8')

        with garak_plugin_cache_guard.plugin_cache_lock(lock_path):
            pass

        self.assertEqual('do-not-truncate', lock_path.read_text(encoding='utf-8'))

    @unittest.skipUnless(hasattr(os, 'O_NOFOLLOW'), 'platform does not support O_NOFOLLOW')
    def test_lock_file_rejects_symlink_without_truncating_target(self):
        target_path = Path(self.tempdir.name) / 'target.txt'
        target_path.write_text('keep me', encoding='utf-8')
        lock_path = Path(self.tempdir.name) / 'symlink.lock'
        lock_path.symlink_to(target_path)

        with self.assertRaises(OSError):
            with garak_plugin_cache_guard.plugin_cache_lock(lock_path):
                pass

        self.assertEqual('keep me', target_path.read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
