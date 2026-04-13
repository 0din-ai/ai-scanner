#!/usr/bin/env python3
"""
PostgreSQL Database Notifier Module

Replaces Unix socket-based IPC with direct PostgreSQL database operations
for multi-pod deployment support. Python writes to shared database, Rails
reads and processes via Solid Queue jobs.

Functions:
    notify_report_running(report_uuid, pid): Mark report as running with PID
    notify_report_ready(report_uuid): Store report data and enqueue processing job
    notify_report_stopped(report_uuid): Clear PID from report

Dependencies:
    psycopg2-binary>=2.9.0

Environment Variables:
    DATABASE_URL: PostgreSQL connection string (required)
        Format: postgresql://user:password@host:port/database
    DATABASE_QUEUE_URL: Queue database connection (optional, falls back to DATABASE_URL + _queue suffix)
"""

import atexit
import json
import logging
import os
import signal
import threading
import uuid
import warnings
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse, urlunparse

import psycopg2
from psycopg2 import OperationalError
from psycopg2 import pool as pg_pool

# Configure logging
logger = logging.getLogger(__name__)

# Path constants (matching Rails paths)
SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent

# Garak reports are in the user's home directory
# Container: HOME=/home/rails -> /home/rails/.local/share/garak/garak_runs/
# Report files: {uuid}.report.jsonl
HOME_DIR = Path(os.environ.get("HOME", "/home/rails"))
REPORTS_PATH = HOME_DIR / ".local" / "share" / "garak" / "garak_runs"

# In container: /rails/storage/logs/
# Log files: {uuid}.log
LOGS_PATH = PROJECT_ROOT / "storage" / "logs"

# In container: /rails/storage/config/
# Config files: {uuid}.json, {uuid}.yml, {uuid}_web.json
CONFIG_PATH = PROJECT_ROOT / "storage" / "config"

# Status enum values (matching Rails RawReportData model)
STATUS_PENDING = 0
STATUS_PROCESSING = 1
# Note: STATUS_COMPLETED not needed - records are deleted after processing

# Report status enum values (matching Rails Report model)
REPORT_STATUS_RUNNING = 1


def is_debug_mode() -> bool:
    """
    Check if debug mode is enabled via LOG_LEVEL environment variable.

    In debug mode, config files are preserved for debugging purposes.
    Matches Rails behavior: Rails.configuration.log_level.to_s == "debug"

    Returns:
        True if LOG_LEVEL=debug, False otherwise
    """
    log_level = os.environ.get("LOG_LEVEL", "").lower()
    return log_level == "debug"


def get_log_file_path(report_uuid: str) -> Path:
    """
    Get the log file path for a report.

    Ruby's LogPathManager creates logs at dated paths like:
        storage/logs/scans/YYYY/MM/DD/{uuid}_{target}.log

    Ruby passes the correct path via LOG_FILE_PATH environment variable.
    This function checks for that env var first, falling back to the flat
    path for backward compatibility.

    Args:
        report_uuid: UUID of the report

    Returns:
        Path to the log file (from LOG_FILE_PATH env var or fallback to flat path)
    """
    log_file_path = os.environ.get("LOG_FILE_PATH")
    if log_file_path:
        return Path(log_file_path)

    # Fallback for backward compatibility (old flat path)
    return LOGS_PATH / f"{report_uuid}.log"


def cleanup_scan_files(report_uuid: str, preserve_config_on_debug: bool = True) -> dict:
    """
    Clean up all temporary files created for a scan.

    This function deletes:
    - JSONL report file: {uuid}.report.jsonl
    - Log file: {uuid}.log
    - Config files (unless debug mode): {uuid}.json, {uuid}.yml, {uuid}_web.json

    Similar to Ruby's ensure block, this uses try/finally pattern to ensure
    cleanup runs regardless of errors. Individual file deletion errors are
    logged but don't stop other deletions.

    Args:
        report_uuid: UUID of the report (scan's uuid, not validation_* prefix)
        preserve_config_on_debug: If True and LOG_LEVEL=debug, preserve config files

    Returns:
        Dict with counts: {"deleted": N, "failed": N, "preserved": N}
    """
    result = {"deleted": 0, "failed": 0, "preserved": 0}
    debug_mode = is_debug_mode() if preserve_config_on_debug else False

    # Get log file path (uses LOG_FILE_PATH env var if set by Ruby)
    log_file_path = get_log_file_path(report_uuid)

    # Files to always delete
    files_to_delete = [
        REPORTS_PATH / f"{report_uuid}.report.jsonl",
        log_file_path,
    ]

    # Config files - only delete if not in debug mode
    config_files = [
        CONFIG_PATH / f"{report_uuid}.json",
        CONFIG_PATH / f"{report_uuid}.yml",
        CONFIG_PATH / f"{report_uuid}_web.json",
    ]

    if debug_mode:
        logger.debug(f"Debug mode enabled - preserving config files for {report_uuid}")
        result["preserved"] = len(config_files)
    else:
        files_to_delete.extend(config_files)

    # Delete each file, logging failures but continuing
    for file_path in files_to_delete:
        try:
            if file_path.exists():
                file_path.unlink()
                result["deleted"] += 1
                logger.debug(f"Deleted: {file_path}")
        except Exception as e:
            result["failed"] += 1
            logger.warning(
                f"[ORPHAN_FILE] Failed to delete {file_path}: {e}. "
                f"File may need manual cleanup."
            )

    if result["deleted"] > 0 or result["failed"] > 0:
        logger.info(
            f"Cleanup for {report_uuid}: deleted={result['deleted']}, "
            f"failed={result['failed']}, preserved={result['preserved']}"
        )

    return result


class HeartbeatThread:
    """
    Background daemon thread that sends periodic heartbeats to the database.

    The heartbeat updates the `heartbeat_at` column in the reports table,
    allowing Rails to detect stale/crashed scans in multi-pod deployments.

    Usage:
        heartbeat = HeartbeatThread(report_uuid)
        heartbeat.start()
        # ... run scan ...
        heartbeat.stop()
    """

    DEFAULT_INTERVAL = 30  # seconds

    def __init__(self, report_uuid: str, interval: int = None):
        """
        Initialize heartbeat thread.

        Args:
            report_uuid: UUID of the report to send heartbeats for
            interval: Seconds between heartbeats (default: 30)
        """
        self.report_uuid = report_uuid
        self.interval = interval if interval is not None else self.DEFAULT_INTERVAL
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()

    def start(self) -> None:
        """Start the heartbeat thread."""
        if self._running:
            logger.warning(f"Heartbeat already running for {self.report_uuid}")
            return

        self._running = True
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        logger.info(f"Heartbeat started for {self.report_uuid} (interval={self.interval}s)")

    def stop(self) -> None:
        """Stop the heartbeat thread gracefully."""
        if not self._running:
            return

        self._running = False
        self._stop_event.set()

        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=5.0)
            if self._thread.is_alive():
                logger.warning(f"Heartbeat thread did not stop cleanly for {self.report_uuid}")

        logger.info(f"Heartbeat stopped for {self.report_uuid}")

    # Max consecutive DB errors before giving up and terminating.
    # Tolerates transient issues (network blips, failovers) while still
    # detecting persistent DB outages. At 30s intervals = ~90s tolerance.
    MAX_CONSECUTIVE_ERRORS = 3

    def _loop(self) -> None:
        """Main heartbeat loop - runs in background thread.

        Checks heartbeat success each cycle. If heartbeat detects the report
        is no longer 'running', sends SIGTERM to terminate the scan process.
        This enables multi-pod stop: Ruby sets status=stopped, Python detects
        it here and self-terminates.

        Transient DB errors are tolerated up to MAX_CONSECUTIVE_ERRORS before
        terminating, to avoid killing healthy scans during brief outages.
        """
        consecutive_errors = 0
        while self._running:
            # Wait for interval or stop signal
            if self._stop_event.wait(timeout=self.interval):
                break  # Stop signal received

            if self._running:
                result = self._send_heartbeat()
                if result == "not_running":
                    # Status changed (stopped/failed/completed) - terminate process
                    logger.info(
                        f"Report {self.report_uuid} status changed, "
                        f"sending SIGTERM to terminate scan"
                    )
                    os.kill(os.getpid(), signal.SIGTERM)
                    break
                elif result == "error":
                    consecutive_errors += 1
                    if consecutive_errors >= self.MAX_CONSECUTIVE_ERRORS:
                        logger.error(
                            f"Heartbeat: {consecutive_errors} consecutive DB errors "
                            f"for {self.report_uuid}, sending SIGTERM"
                        )
                        os.kill(os.getpid(), signal.SIGTERM)
                        break
                else:
                    consecutive_errors = 0

    def _send_heartbeat(self) -> str:
        """Send a single heartbeat to the database using pooled connection.

        Returns:
            "ok" if heartbeat succeeded,
            "not_running" if report is no longer in running status,
            "error" if a DB/connection error occurred.
        """
        try:
            with pooled_connection("primary") as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE reports
                        SET heartbeat_at = NOW()
                        WHERE uuid = %s AND status = %s
                        """,
                        (self.report_uuid, REPORT_STATUS_RUNNING),
                    )
                    rows_affected = cur.rowcount
                conn.commit()

                if rows_affected > 0:
                    logger.debug(f"Heartbeat sent for {self.report_uuid}")
                    return "ok"
                else:
                    # Report may have been marked failed/completed by another process
                    logger.warning(f"Heartbeat: report {self.report_uuid} not found or not running")
                    return "not_running"

        except Exception as e:
            logger.error(f"Heartbeat error for {self.report_uuid}: {e}")
            return "error"


class JournalSyncThread:
    """
    Background daemon thread that periodically syncs the JSONL report file
    from disk to the raw_report_data table.

    This ensures partial scan progress is persisted to the database even if
    the garak process is killed unexpectedly (deployment, OOM, pod eviction).

    The thread reads the full JSONL file each cycle and upserts it to the
    database. For resumed scans, a prefix containing previously saved JSONL
    data is prepended to the current file content.

    Usage:
        journal = JournalSyncThread(report_uuid, jsonl_path)
        journal.start()
        # ... run scan ...
        journal.final_sync()  # After garak completes
        journal.stop()
    """

    DEFAULT_INTERVAL = 10  # seconds

    def __init__(
        self,
        report_uuid: str,
        jsonl_path: Path,
        prefix: str = "",
        interval: int = None,
    ):
        """
        Initialize journal sync thread.

        Args:
            report_uuid: UUID of the report
            jsonl_path: Path to garak's JSONL output file
            prefix: Previously saved JSONL from an interrupted scan (for resumption)
            interval: Seconds between sync cycles (default: 10)
        """
        self.report_uuid = report_uuid
        self.jsonl_path = jsonl_path
        self.prefix = prefix
        self.interval = interval if interval is not None else self.DEFAULT_INTERVAL
        self._running = False
        self._final_synced = False
        self._cancelled = False
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._sync_lock = threading.Lock()
        self._last_synced_content: Optional[str] = None
        self._report_id: Optional[int] = None  # Cached after first lookup
        self._consecutive_failures: int = 0

    def start(self) -> None:
        """Start the journal sync thread."""
        if self._running:
            logger.warning(f"JournalSync already running for {self.report_uuid}")
            return

        self._running = True
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        logger.info(
            f"JournalSync started for {self.report_uuid} "
            f"(interval={self.interval}s, prefix={len(self.prefix)} bytes)"
        )

    def stop(self) -> bool:
        """Stop the thread gracefully with a final sync.

        Returns:
            True if final sync completed (data is up-to-date in DB),
            False if thread timed out or final sync failed.
        """
        if not self._running:
            return True

        self._running = False
        self._stop_event.set()

        # Join the background thread first to avoid concurrent _sync() calls
        thread_stopped = True
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=5.0)
            if self._thread.is_alive():
                logger.warning(
                    f"JournalSync thread did not stop cleanly for {self.report_uuid}"
                )
                thread_stopped = False

        if not thread_stopped:
            # Thread still running — cancel any in-flight or future syncs.
            # Acquire the lock to wait for a running _sync() to finish,
            # then mark as cancelled so no further DB writes occur.
            acquired = self._sync_lock.acquire(timeout=5.0)
            self._cancelled = True
            if acquired:
                self._sync_lock.release()
            logger.info(f"JournalSync stopped (timed out) for {self.report_uuid}")
            return False

        # Final sync after thread has stopped — skip if final_sync() was already
        # called (scan files may have been cleaned up)
        sync_success = True
        if not self._final_synced:
            sync_success = self._sync()

        logger.info(f"JournalSync stopped for {self.report_uuid}")
        return sync_success

    def final_sync(self) -> bool:
        """Explicit final sync — called on normal scan completion."""
        result = self._sync()
        if result:
            self._final_synced = True
        return result

    def _loop(self) -> None:
        """Main sync loop — runs in background thread."""
        while self._running:
            if self._stop_event.wait(timeout=self.interval):
                break  # Stop signal received

            if self._running:
                if self._sync():
                    self._consecutive_failures = 0
                else:
                    self._consecutive_failures += 1
                    if self._consecutive_failures >= 3:
                        logger.warning(
                            f"JournalSync: {self._consecutive_failures} consecutive "
                            f"sync failures for {self.report_uuid} — data loss risk"
                        )

    def _sync(self) -> bool:
        """Read JSONL file from disk and upsert to raw_report_data."""
        try:
            # Read current file content (may not exist yet if garak hasn't started)
            file_content = ""
            if self.jsonl_path.exists():
                file_content = self.jsonl_path.read_text(encoding="utf-8")

            # Build full content: prefix (old data from previous run) + new file content
            full_content = self.prefix + file_content if self.prefix else file_content

            # Skip if nothing to sync or content unchanged
            if not full_content or not full_content.strip():
                return True
            if full_content == self._last_synced_content:
                return True

            with self._sync_lock:
                if self._cancelled:
                    logger.debug(
                        f"JournalSync: sync cancelled for {self.report_uuid}"
                    )
                    return False

                with pooled_connection("primary") as conn:
                    # Disable autocommit so INSERT runs inside an explicit
                    # transaction that we can rollback if cancelled.
                    conn.autocommit = False
                    with conn.cursor() as cur:
                        if self._report_id is None:
                            cur.execute(
                                "SELECT id FROM reports WHERE uuid = %s",
                                (self.report_uuid,),
                            )
                            result = cur.fetchone()
                            if not result:
                                logger.warning(
                                    f"JournalSync: report not found: "
                                    f"{self.report_uuid}"
                                )
                                return False
                            self._report_id = result[0]

                        report_id = self._report_id
                        now = datetime.now(timezone.utc)
                        cur.execute(
                            """
                            INSERT INTO raw_report_data
                                (report_id, jsonl_data, status,
                                 created_at, updated_at)
                            VALUES (%s, %s, %s, %s, %s)
                            ON CONFLICT (report_id) DO UPDATE SET
                                jsonl_data = EXCLUDED.jsonl_data,
                                updated_at = EXCLUDED.updated_at
                            """,
                            (report_id, full_content, STATUS_PENDING, now, now),
                        )
                    # Re-check cancellation before committing to prevent
                    # stale writes when stop() set _cancelled while we were
                    # executing the INSERT (lock-acquire-timeout race).
                    if self._cancelled:
                        conn.rollback()
                        logger.debug(
                            f"JournalSync: sync cancelled before commit "
                            f"for {self.report_uuid}"
                        )
                        return False
                    conn.commit()

            self._last_synced_content = full_content
            logger.debug(
                f"JournalSync: synced {len(full_content)} bytes for {self.report_uuid}"
            )
            return True

        except Exception as e:
            logger.error(f"JournalSync error for {self.report_uuid}: {e}")
            return False


def load_existing_jsonl_prefix(report_uuid: str) -> str:
    """
    Load existing partial JSONL from raw_report_data for scan resumption.

    When a scan is retried after interruption, this function retrieves the
    JSONL data that was saved by JournalSyncThread before the crash.

    Args:
        report_uuid: UUID of the report

    Returns:
        Previously saved JSONL data, or empty string if none exists
    """
    try:
        with pooled_connection("primary") as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT rrd.jsonl_data
                    FROM raw_report_data rrd
                    JOIN reports r ON r.id = rrd.report_id
                    WHERE r.uuid = %s
                    """,
                    (report_uuid,),
                )
                result = cur.fetchone()
                if result and result[0]:
                    data = result[0]
                    # Ensure trailing newline so concatenation with new file
                    # content doesn't corrupt the boundary between lines
                    if not data.endswith("\n"):
                        data += "\n"
                    logger.info(
                        f"Found existing JSONL prefix for {report_uuid} "
                        f"({len(data)} bytes)"
                    )
                    return data
        return ""
    except Exception as e:
        logger.error(f"Error loading JSONL prefix for {report_uuid}: {e}")
        raise


def _get_database_url(suffix: str = "") -> str:
    """
    Get database URL, optionally with suffix for queue/cache databases.

    Args:
        suffix: Database name suffix (e.g., "_queue" for Solid Queue database)

    Returns:
        PostgreSQL connection string

    Raises:
        ValueError: If DATABASE_URL is not set
    """
    base_url = os.environ.get("DATABASE_URL")
    if not base_url:
        raise ValueError("DATABASE_URL environment variable is not set")

    if not suffix:
        return base_url

    # Check for explicit override (e.g., DATABASE_QUEUE_URL)
    override_key = f"DATABASE{suffix.upper()}_URL"
    override_url = os.environ.get(override_key)
    if override_url:
        return override_url

    # Parse URL and add suffix to database name
    parsed = urlparse(base_url)
    db_name = parsed.path.lstrip("/")
    new_path = f"/{db_name}{suffix}"
    modified = parsed._replace(path=new_path)
    return urlunparse(modified)


class ConnectionPoolManager:
    """
    Thread-safe connection pool manager for PostgreSQL databases.

    Implements singleton pattern with lazy initialization.
    Pools are created on first use and cleaned up at process exit.

    Environment Variables:
        DB_POOL_MIN_CONN: Minimum connections per pool (default: 1)
        DB_POOL_MAX_CONN: Maximum connections per pool (default: 5)

    Usage:
        with get_pool_manager().get_connection("primary") as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
    """

    _instance = None
    _lock = threading.Lock()

    # Pool configuration (can be overridden via environment)
    DEFAULT_MIN_CONN = 1
    DEFAULT_MAX_CONN = 5

    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super().__new__(cls)
                    cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return

        self._pools: dict[str, pg_pool.ThreadedConnectionPool] = {}
        self._pool_locks: dict[str, threading.Lock] = {}
        self._min_conn = int(os.environ.get("DB_POOL_MIN_CONN", self.DEFAULT_MIN_CONN))
        self._max_conn = int(os.environ.get("DB_POOL_MAX_CONN", self.DEFAULT_MAX_CONN))
        self._initialized = True

        # Register cleanup on process exit
        atexit.register(self.close_all_pools)
        logger.debug(f"ConnectionPoolManager initialized (min={self._min_conn}, max={self._max_conn})")

    def _get_or_create_pool(self, database: str) -> pg_pool.ThreadedConnectionPool:
        """Get existing pool or create new one for database."""
        with self._lock:
            if database not in self._pool_locks:
                self._pool_locks[database] = threading.Lock()

        with self._pool_locks[database]:
            if database not in self._pools:
                url = _get_database_url("_queue" if database == "queue" else "")
                self._pools[database] = pg_pool.ThreadedConnectionPool(
                    minconn=self._min_conn,
                    maxconn=self._max_conn,
                    dsn=url
                )
                logger.info(f"Created connection pool for '{database}' database")

            return self._pools[database]

    @contextmanager
    def get_connection(self, database: str = "primary"):
        """
        Get a connection from the pool as a context manager.

        Connection is automatically returned to pool on exit.
        If pool is exhausted, falls back to creating new connection.

        Args:
            database: "primary" or "queue"

        Yields:
            psycopg2 connection object
        """
        pool = None
        conn = None
        from_pool = False

        try:
            pool = self._get_or_create_pool(database)
            conn = pool.getconn()
            from_pool = True

            # Reset connection state - ensure clean slate for caller
            # This is important because previous user may have changed autocommit
            try:
                conn.rollback()  # Clear any pending transaction
                conn.autocommit = True  # Reset to default state
            except Exception:
                pass

            # Health check - test connection is alive
            if not self._is_connection_healthy(conn):
                logger.warning("Unhealthy connection from pool, creating new one")
                pool.putconn(conn, close=True)
                conn = pool.getconn()
                # Reset new connection too
                try:
                    conn.rollback()
                    conn.autocommit = True
                except Exception:
                    pass

            yield conn

        except pg_pool.PoolError as e:
            # Pool exhausted - fall back to direct connection
            logger.warning(f"Connection pool exhausted for {database}: {e}")
            conn = psycopg2.connect(_get_database_url("_queue" if database == "queue" else ""))
            from_pool = False
            yield conn

        finally:
            if conn:
                if from_pool and pool:
                    try:
                        # Reset connection state before returning to pool
                        conn.rollback()
                        conn.autocommit = True  # Reset to default for next user
                        pool.putconn(conn)
                    except Exception as e:
                        logger.error(f"Error returning connection to pool: {e}")
                        try:
                            pool.putconn(conn, close=True)
                        except Exception:
                            pass
                else:
                    try:
                        conn.close()
                    except Exception:
                        pass

    def _is_connection_healthy(self, conn) -> bool:
        """Test if connection is still valid."""
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
            return True
        except (OperationalError, Exception):
            return False

    def close_all_pools(self):
        """Close all connection pools. Called on process exit."""
        for database, pool in self._pools.items():
            try:
                pool.closeall()
                logger.info(f"Closed connection pool for '{database}'")
            except Exception as e:
                logger.error(f"Error closing pool for {database}: {e}")
        self._pools.clear()


# Module-level singleton instance
_pool_manager: Optional[ConnectionPoolManager] = None
_pool_manager_lock = threading.Lock()


def get_pool_manager() -> ConnectionPoolManager:
    """Get or create the singleton pool manager."""
    global _pool_manager
    if _pool_manager is None:
        with _pool_manager_lock:
            if _pool_manager is None:
                _pool_manager = ConnectionPoolManager()
    return _pool_manager


@contextmanager
def pooled_connection(database: str = "primary"):
    """
    Get a pooled connection as a context manager.

    Preferred over get_db_connection() for all operations.
    Connection is automatically returned to pool on exit.

    Args:
        database: "primary" or "queue"

    Yields:
        psycopg2 connection object

    Example:
        with pooled_connection("primary") as conn:
            with conn.cursor() as cur:
                cur.execute("UPDATE reports SET status = 1 WHERE uuid = %s", (uuid,))
            conn.commit()
    """
    with get_pool_manager().get_connection(database) as conn:
        yield conn


def get_db_connection(database: str = "primary"):
    """
    Get PostgreSQL connection from DATABASE_URL.

    DEPRECATED: Use `pooled_connection(database)` context manager instead.
    This function creates a non-pooled connection and the caller is responsible
    for closing it. The pooled_connection() context manager is preferred as it
    automatically handles connection lifecycle and reuses connections.

    Args:
        database: Which database to connect to ("primary" or "queue")

    Returns:
        psycopg2 connection object (caller must close!)

    Raises:
        ValueError: If DATABASE_URL is not set
        psycopg2.Error: If connection fails
    """
    warnings.warn(
        "get_db_connection() is deprecated. Use pooled_connection() context manager instead.",
        DeprecationWarning,
        stacklevel=2
    )
    suffix = "_queue" if database == "queue" else ""
    url = _get_database_url(suffix)
    logger.debug(f"Creating direct connection to database: {database}")
    return psycopg2.connect(url)


def _enqueue_broadcast_stats_job(company_id: int, queue_conn) -> int:
    """
    Enqueue BroadcastRunningStatsJob in Solid Queue.

    This function creates the job record for broadcasting running stats updates.
    Called after Python updates report status to 'running' via direct SQL,
    since that bypasses Rails callbacks.

    Args:
        company_id: Company ID for company-scoped broadcast stats
        queue_conn: Connection to the queue database

    Returns:
        Solid Queue job ID
    """
    job_uuid = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    now_str = now.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

    # ActiveJob serialization format (matching Rails BroadcastRunningStatsJob)
    arguments_payload = {
        "job_class": "BroadcastRunningStatsJob",
        "job_id": job_uuid,
        "provider_job_id": None,
        "queue_name": "default",
        "priority": None,
        "arguments": [company_id],
        "executions": 0,
        "exception_executions": {},
        "locale": "en",
        "timezone": "UTC",
        "enqueued_at": now_str,
        "scheduled_at": now_str,
    }

    concurrency_key = f"BroadcastRunningStatsJob/broadcast_running_stats:{company_id}"

    with queue_conn.cursor() as queue_cur:
        # Insert into solid_queue_jobs
        queue_cur.execute(
            """
            INSERT INTO solid_queue_jobs
                (class_name, arguments, queue_name, priority, active_job_id,
                 concurrency_key, scheduled_at, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
            """,
            (
                "BroadcastRunningStatsJob",
                json.dumps(arguments_payload),
                "default",
                0,  # priority
                job_uuid,
                concurrency_key,
                now,  # scheduled_at
                now,  # created_at
                now,  # updated_at
            ),
        )
        job_id = queue_cur.fetchone()[0]

        # Insert into solid_queue_ready_executions for immediate processing
        queue_cur.execute(
            """
            INSERT INTO solid_queue_ready_executions
                (job_id, queue_name, priority, created_at)
            VALUES (%s, %s, %s, %s)
            """,
            (job_id, "default", 0, now),
        )

    logger.debug(f"Enqueued BroadcastRunningStatsJob: job_id={job_id}")
    return job_id


def notify_report_running(report_uuid: str, pid: int) -> bool:
    """
    Update report status to running with PID using pooled connection.

    Called when garak scan starts to inform Rails of the running process.
    Also enqueues BroadcastRunningStatsJob to update the UI immediately,
    since direct SQL updates bypass Rails callbacks.

    Args:
        report_uuid: UUID of the report
        pid: Process ID of the garak scanner

    Returns:
        True on success, False on failure
    """
    logger.info(f"Notifying report running: {report_uuid} (pid={pid})")
    try:
        with pooled_connection("primary") as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE reports
                    SET status = %s, pid = %s, heartbeat_at = NOW(), updated_at = NOW()
                    WHERE uuid = %s
                    RETURNING company_id
                    """,
                    (REPORT_STATUS_RUNNING, pid, report_uuid),
                )
                report_row = cur.fetchone()
            conn.commit()

            if report_row is None:
                logger.warning(f"Report not found: {report_uuid}")
                return False

            company_id = report_row[0]

            logger.info(f"Report {report_uuid} marked as running (pid={pid})")

        # Enqueue broadcast job to update UI (bypasses Rails callbacks)
        try:
            with pooled_connection("queue") as queue_conn:
                queue_conn.autocommit = False
                _enqueue_broadcast_stats_job(company_id, queue_conn)
                queue_conn.commit()
                logger.debug(f"Broadcast stats job enqueued for {report_uuid}")
        except Exception as broadcast_err:
            # Non-fatal: status update succeeded, UI will catch up eventually
            logger.warning(f"Failed to enqueue broadcast job: {broadcast_err}")

        return True

    except Exception as e:
        logger.error(f"Error in notify_report_running: {e}")
        return False


def notify_report_stopped(report_uuid: str, expected_pid: int = None) -> bool:
    """
    Clear PID from report using pooled connection (owner-process guard).

    Only clears PID when the stored PID matches the caller's PID. This
    prevents forked child processes from corrupting parent lifecycle state:
    a child that inherits the signal handler and calls this function will
    have a different os.getpid(), so the UPDATE WHERE clause won't match.

    Args:
        report_uuid: UUID of the report
        expected_pid: PID to match against stored PID. Defaults to os.getpid().

    Returns:
        True if PID was cleared, False on mismatch or failure
    """
    my_pid = os.getpid()
    pid_to_match = expected_pid if expected_pid is not None else my_pid

    logger.info(f"Notifying report stopped: {report_uuid} (expected_pid={pid_to_match}, caller_pid={my_pid})")
    try:
        with pooled_connection("primary") as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE reports
                    SET pid = NULL, updated_at = NOW()
                    WHERE uuid = %s AND pid = %s
                    """,
                    (report_uuid, pid_to_match),
                )
                rows_affected = cur.rowcount
            conn.commit()

            if rows_affected == 0:
                logger.warning(
                    f"Report {report_uuid} PID not cleared: stored PID does not match "
                    f"expected PID {pid_to_match} (caller PID {my_pid})"
                )
                return False

            logger.info(f"Report {report_uuid} PID cleared (matched pid={pid_to_match})")
            return True

    except Exception as e:
        logger.error(f"Error in notify_report_stopped: {e}")
        return False


def _enqueue_process_report_job(report_id: int, queue_conn) -> int:
    """
    Enqueue ProcessReportJob in Solid Queue.

    This function creates the job record in the queue database using the
    same format that Rails/Solid Queue expects. The job will be processed
    by the Rails ProcessReportJob which calls Reports::Process.

    Args:
        report_id: ID of the report to process
        queue_conn: Connection to the queue database

    Returns:
        Solid Queue job ID
    """
    job_uuid = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    now_str = now.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

    # ActiveJob serialization format (matching Rails ProcessReportJob)
    arguments_payload = {
        "job_class": "ProcessReportJob",
        "job_id": job_uuid,
        "provider_job_id": None,
        "queue_name": "default",
        "priority": None,
        "arguments": [report_id],  # Integer, Rails will convert
        "executions": 0,
        "exception_executions": {},
        "locale": "en",
        "timezone": "UTC",
        "enqueued_at": now_str,
        "scheduled_at": now_str,
    }

    # Concurrency key format: JobClass/key_from_proc
    # Must match Rails: limits_concurrency key: ->(report_id) { "process_report_#{report_id}" }
    concurrency_key = f"ProcessReportJob/process_report_{report_id}"

    with queue_conn.cursor() as queue_cur:
        # Insert into solid_queue_jobs
        queue_cur.execute(
            """
            INSERT INTO solid_queue_jobs
                (class_name, arguments, queue_name, priority, active_job_id,
                 concurrency_key, scheduled_at, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
            """,
            (
                "ProcessReportJob",
                json.dumps(arguments_payload),
                "default",
                0,  # priority
                job_uuid,
                concurrency_key,
                now,  # scheduled_at
                now,  # created_at
                now,  # updated_at
            ),
        )
        job_id = queue_cur.fetchone()[0]

        # Insert into solid_queue_ready_executions for immediate processing
        queue_cur.execute(
            """
            INSERT INTO solid_queue_ready_executions
                (job_id, queue_name, priority, created_at)
            VALUES (%s, %s, %s, %s)
            """,
            (job_id, "default", 0, now),
        )

    logger.debug(f"Enqueued ProcessReportJob: job_id={job_id}, active_job_id={job_uuid}")
    return job_id


def notify_report_ready(report_uuid: str, prefix: str = "") -> bool:
    """
    Store report data in database and enqueue processing job using pooled connections.

    Called when garak scan completes successfully. This function:
    1. Reads JSONL and log files from disk
    2. Stores them in raw_report_data table (PRIMARY COMMIT FIRST)
    3. Enqueues ProcessReportJob in Solid Queue (QUEUE COMMIT SECOND)
    4. Deletes local files (only after successful primary commit)

    Commit Order (Data-First Pattern):
        Primary database is committed before queue database. This ensures:
        - Job never runs before data exists (prevents infinite retry storms)
        - If queue commit fails, data is orphaned but recoverable
        - OrphanRawReportDataJob detects and recovers orphans within 5 minutes

    On failure, files are preserved for manual retry or debugging.

    Args:
        report_uuid: UUID of the report
        prefix: JSONL prefix from a previous interrupted run (for resumed scans).
            When provided, prepended to the disk file content so that previously
            completed probe data is not lost.

    Returns:
        True on success (including when queue fails but data is saved)
        False on failure (primary commit failed or file read error)
    """
    logger.info(f"Notifying report ready: {report_uuid}")

    # Build file paths
    # JSONL is always at the standard garak output location
    jsonl_path = REPORTS_PATH / f"{report_uuid}.report.jsonl"
    # Log path uses LOG_FILE_PATH env var (set by Ruby) for correct dated path
    logs_path = get_log_file_path(report_uuid)

    # Read files BEFORE starting transaction
    jsonl_data: Optional[str] = None
    logs_data: Optional[str] = None

    try:
        if jsonl_path.exists():
            jsonl_data = jsonl_path.read_text(encoding="utf-8")
            logger.debug(f"Read JSONL file: {jsonl_path} ({len(jsonl_data)} bytes)")
        else:
            logger.error(f"JSONL file not found: {jsonl_path}")
            return False

        if logs_path.exists():
            logs_data = logs_path.read_text(encoding="utf-8")
            logger.debug(f"Read logs file: {logs_path} ({len(logs_data)} bytes)")
        else:
            logger.debug(f"Logs file not found (optional): {logs_path}")

    except Exception as e:
        logger.error(f"Error reading report files: {e}")
        return False

    # Prepend prefix from previous interrupted run (resumed scans)
    if prefix and jsonl_data:
        jsonl_data = prefix + jsonl_data
        logger.debug(
            f"Prepended {len(prefix)} byte prefix to JSONL data "
            f"(total: {len(jsonl_data)} bytes)"
        )

    # Validate JSONL data is not empty
    if not jsonl_data or not jsonl_data.strip():
        logger.error(f"JSONL file is empty: {jsonl_path}")
        return False

    try:
        # Use nested context managers for both pooled connections
        with pooled_connection("primary") as primary_conn, \
             pooled_connection("queue") as queue_conn:

            # Begin transactions on both connections
            primary_conn.autocommit = False
            queue_conn.autocommit = False

            # Set statement timeout to prevent long-running transactions
            with primary_conn.cursor() as timeout_cur:
                timeout_cur.execute("SET statement_timeout = '30s'")
            with queue_conn.cursor() as timeout_cur:
                timeout_cur.execute("SET statement_timeout = '30s'")

            with primary_conn.cursor() as cur:
                # Get report ID from UUID
                cur.execute("SELECT id FROM reports WHERE uuid = %s", (report_uuid,))
                result = cur.fetchone()
                if not result:
                    logger.error(f"Report not found: {report_uuid}")
                    return False

                report_id = result[0]
                logger.debug(f"Found report: id={report_id}, uuid={report_uuid}")

                # Insert into raw_report_data
                now = datetime.now(timezone.utc)
                cur.execute(
                    """
                    INSERT INTO raw_report_data
                        (report_id, jsonl_data, logs_data, status, created_at, updated_at)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT (report_id) DO UPDATE SET
                        jsonl_data = EXCLUDED.jsonl_data,
                        logs_data = EXCLUDED.logs_data,
                        status = EXCLUDED.status,
                        updated_at = EXCLUDED.updated_at
                    """,
                    (report_id, jsonl_data, logs_data, STATUS_PENDING, now, now),
                )
                logger.debug(f"Inserted raw_report_data for report_id={report_id}")

                # Enqueue processing job (uses queue_conn)
                job_id = _enqueue_process_report_job(report_id, queue_conn)
                logger.debug(f"Enqueued job_id={job_id} for report_id={report_id}")

            # COMMIT ORDER: Data first, job second (Data-First pattern)
            #
            # This order ensures:
            # - Job never runs before data exists (no infinite retry storms)
            # - If queue commit fails after primary commit, data is orphaned but recoverable
            # - OrphanRawReportDataJob will detect and create missing jobs
            #
            # Failure modes:
            # - Both succeed: Normal flow, job processes data
            # - Primary fails: Both rolled back, files preserved, return False
            # - Queue fails after primary: Data safe, orphan poller recovers within 5 min
            primary_conn.commit()
            logger.info(f"Report {report_uuid} data committed to primary database")

            try:
                queue_conn.commit()
                logger.info(f"Report {report_uuid} job enqueued (job_id={job_id})")
            except Exception as queue_error:
                # Data is safe in primary! OrphanRawReportDataJob will create the missing job.
                # This is the recoverable failure mode - much better than infinite retries.
                logger.warning(
                    f"Report {report_uuid}: queue commit failed ({queue_error}). "
                    f"Data saved successfully. OrphanRawReportDataJob will recover within 5 minutes."
                )
                # Still return True - data is safe, recovery will happen automatically

            # Clean up all temporary files after successful primary commit
            # This includes JSONL, logs, and config files (respects LOG_LEVEL=debug)
            cleanup_scan_files(report_uuid)

            return True

    except Exception as e:
        logger.error(f"Error in notify_report_ready: {e}")
        # Files are preserved for manual retry or debugging
        # Note: pooled_connection handles connection cleanup and rollback automatically
        return False


def notify_report_ready_from_synced(report_uuid: str) -> bool:
    """
    Enqueue ProcessReportJob using already-synced raw_report_data.

    Unlike notify_report_ready(), this does NOT re-read the JSONL file from disk.
    JournalSyncThread has already synced the full JSONL content to raw_report_data.

    This function only:
    1. Reads the log file and updates logs_data on raw_report_data
    2. Enqueues ProcessReportJob
    3. Cleans up local files

    Args:
        report_uuid: UUID of the report

    Returns:
        True on success, False on failure
    """
    logger.info(f"Notifying report ready (from synced data): {report_uuid}")

    # Read log file (JSONL already synced by JournalSyncThread)
    logs_path = get_log_file_path(report_uuid)
    logs_data: Optional[str] = None
    if logs_path.exists():
        try:
            logs_data = logs_path.read_text(encoding="utf-8")
            logger.debug(f"Read logs file: {logs_path} ({len(logs_data)} bytes)")
        except Exception as e:
            logger.warning(f"Failed to read log file: {e}")

    try:
        with pooled_connection("primary") as primary_conn, \
             pooled_connection("queue") as queue_conn:

            primary_conn.autocommit = False
            queue_conn.autocommit = False

            with primary_conn.cursor() as timeout_cur:
                timeout_cur.execute("SET statement_timeout = '30s'")
            with queue_conn.cursor() as timeout_cur:
                timeout_cur.execute("SET statement_timeout = '30s'")

            with primary_conn.cursor() as cur:
                cur.execute(
                    "SELECT id FROM reports WHERE uuid = %s", (report_uuid,)
                )
                result = cur.fetchone()
                if not result:
                    logger.error(f"Report not found: {report_uuid}")
                    return False

                report_id = result[0]

                # Verify raw_report_data exists (JournalSyncThread should have created it)
                cur.execute(
                    "SELECT 1 FROM raw_report_data WHERE report_id = %s",
                    (report_id,),
                )
                if not cur.fetchone():
                    logger.error(
                        f"No raw_report_data found for report_id={report_id} "
                        f"(uuid={report_uuid}) — JournalSync may have failed"
                    )
                    return False

                # Update logs_data on existing raw_report_data record
                if logs_data:
                    now = datetime.now(timezone.utc)
                    cur.execute(
                        """
                        UPDATE raw_report_data
                        SET logs_data = %s, updated_at = %s
                        WHERE report_id = %s
                        """,
                        (logs_data, now, report_id),
                    )

                job_id = _enqueue_process_report_job(report_id, queue_conn)
                logger.debug(f"Enqueued job_id={job_id} for report_id={report_id}")

            # Data-first commit pattern (same as notify_report_ready)
            primary_conn.commit()
            logger.info(f"Report {report_uuid} logs committed to primary database")

            try:
                queue_conn.commit()
                logger.info(f"Report {report_uuid} job enqueued (job_id={job_id})")
            except Exception as queue_error:
                logger.warning(
                    f"Report {report_uuid}: queue commit failed ({queue_error}). "
                    f"Data saved successfully. Normal retry flow will re-run the "
                    f"scan and detect completed probes, or OrphanRawReportDataJob "
                    f"will recover once report reaches a terminal status."
                )

            cleanup_scan_files(report_uuid)
            return True

    except Exception as e:
        logger.error(f"Error in notify_report_ready_from_synced: {e}")
        return False


# Configure logging when module is imported
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
