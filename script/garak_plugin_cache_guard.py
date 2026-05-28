import json
import logging
import os
import stat
import threading
from contextlib import contextmanager
from pathlib import Path

try:
    import fcntl
except ImportError:  # pragma: no cover - Linux production path always has fcntl
    fcntl = None


DEFAULT_PLUGIN_CACHE_LOCK_PATH = Path.home() / ".cache" / "garak" / "ai-scanner-plugin-cache.lock"
PLUGIN_CACHE_LOCK_PATH = Path(os.environ.get("GARAK_PLUGIN_CACHE_LOCK", DEFAULT_PLUGIN_CACHE_LOCK_PATH))
_PLUGIN_CACHE_THREAD_LOCK = threading.RLock()
_PLUGIN_CACHE_INSTALL_LOCK = threading.Lock()
_PLUGIN_CACHE_LOCK_STATE = threading.local()


def _open_lock_file(lock_path):
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW

    fd = os.open(lock_path, flags, 0o600)
    try:
        file_stat = os.fstat(fd)
        if not stat.S_ISREG(file_stat.st_mode):
            raise OSError(f"garak plugin cache lock path is not a regular file: {lock_path}")
        os.fchmod(fd, 0o600)
        return os.fdopen(fd, "r+", encoding="utf-8")
    except Exception:
        os.close(fd)
        raise


@contextmanager
def plugin_cache_lock(lock_path=PLUGIN_CACHE_LOCK_PATH):
    """Serialize garak plugin-cache readers and writers across processes.

    garak's PluginCache mutex only protects threads in a single Python process.
    ai-scanner can run several garak processes concurrently in the same
    container, all sharing garak's user plugin_cache.json. Holding this file
    lock around cache load/build prevents readers from observing a partially
    written JSON file. The default lock lives alongside garak's user cache; an
    env override is opened without truncation and without following symlinks.
    """
    depth = getattr(_PLUGIN_CACHE_LOCK_STATE, "depth", 0)
    if depth > 0:
        _PLUGIN_CACHE_LOCK_STATE.depth = depth + 1
        try:
            yield
        finally:
            _PLUGIN_CACHE_LOCK_STATE.depth -= 1
        return

    with _PLUGIN_CACHE_THREAD_LOCK:
        lock_path = Path(lock_path)
        lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with _open_lock_file(lock_path) as lock_file:
            if fcntl is not None:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            _PLUGIN_CACHE_LOCK_STATE.depth = 1
            try:
                yield
            finally:
                _PLUGIN_CACHE_LOCK_STATE.depth = 0
                if fcntl is not None:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def install_plugin_cache_guard():
    """Patch garak PluginCache I/O to be process-safe and self-healing.

    If a stale or unguarded process left plugin_cache.json truncated, garak
    normally raises JSONDecodeError before a scan can start. Rebuild once under
    the same lock, then retry the load so the scan can proceed with a healthy
    cache.
    """
    import garak._plugins as garak_plugins

    with _PLUGIN_CACHE_INSTALL_LOCK:
        plugin_cache_class = garak_plugins.PluginCache
        if getattr(plugin_cache_class, "_ai_scanner_cache_guard_installed", False):
            return

        original_load_plugin_cache = plugin_cache_class._load_plugin_cache
        original_build_plugin_cache = plugin_cache_class._build_plugin_cache

        def guarded_load_plugin_cache(self):
            with plugin_cache_lock():
                try:
                    return original_load_plugin_cache(self)
                except json.JSONDecodeError as error:
                    cache_filename = getattr(self, "_user_plugin_cache_filename", None)
                    cache_path = Path(cache_filename) if cache_filename else None
                    logging.warning(
                        "garak plugin cache is corrupt at %s (%s); rebuilding under lock",
                        cache_path or "unknown path",
                        error,
                    )
                    try:
                        if cache_path is not None and cache_path.exists():
                            cache_path.unlink()
                    except OSError as unlink_error:
                        logging.warning("could not remove corrupt garak plugin cache %s: %s", cache_path, unlink_error)

                    original_build_plugin_cache(self)
                    return original_load_plugin_cache(self)

        def guarded_build_plugin_cache(self):
            with plugin_cache_lock():
                return original_build_plugin_cache(self)

        plugin_cache_class._load_plugin_cache = guarded_load_plugin_cache
        plugin_cache_class._build_plugin_cache = guarded_build_plugin_cache
        plugin_cache_class._ai_scanner_cache_guard_installed = True
