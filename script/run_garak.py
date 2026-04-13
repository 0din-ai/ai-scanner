#!/usr/bin/env python3
"""
Garak Scanner Runner Script

This script runs a Garak scan with the provided parameters and communicates with Rails
via PostgreSQL database operations for multi-pod deployment support.

Communication Flow:
    1. notify_report_running: UPDATE reports SET status=1, pid=X
    2. notify_report_ready: INSERT into raw_report_data, enqueue ProcessReportJob
    3. notify_report_stopped: UPDATE reports SET pid=NULL WHERE pid matches caller (PID-match guard)

Environment Variables:
    DATABASE_URL: PostgreSQL connection string (required)
        Format: postgresql://user:password@host:port/database
    REPORT_UUID: Report UUID for correlation (optional)
    SCAN_ID: Scan ID for correlation (optional)
    SCAN_NAME: Scan name for correlation (optional)
    TARGET_ID: Target ID for correlation (optional)
    TARGET_NAME: Target name for correlation (optional)

Usage:
    python3 run_garak.py <report_uuid> <garak_params>

Example:
    python3 run_garak.py "12345678-1234-1234-1234-123456789012" "--model_type openai.chat --model_name gpt-3.5-turbo --probes probe1,probe2"
"""

import os
import sys
import shlex
import signal
import logging

from pathlib import Path

from db_notifier import (
    notify_report_running as db_notify_running,
    notify_report_ready as db_notify_ready,
    notify_report_ready_from_synced as db_notify_ready_from_synced,
    notify_report_stopped as db_notify_stopped,
    load_existing_jsonl_prefix,
    HeartbeatThread,
    JournalSyncThread,
    REPORTS_PATH,
)

logger = logging.getLogger(__name__)

# Global variables for signal handler cleanup
current_report_uuid = None
current_heartbeat = None
current_journal_sync = None

# Capture the main process PID at module load time so forked children can
# detect they are NOT the owner and skip parent-only cleanup.
_main_pid = os.getpid()

def signal_handler(signum, frame):
    """Handle termination signals to ensure cleanup.

    Only the original main process performs report cleanup. Forked children
    (e.g. garak internals) inherit this handler via fork(), but must not
    execute parent-only cleanup (notify_report_stopped, heartbeat/journal
    stop) because that corrupts the parent's lifecycle state.
    """
    my_pid = os.getpid()
    if my_pid != _main_pid:
        # Child process — hard exit without unwinding into parent cleanup frames
        logger.warning(
            f"Signal {signum} in child process (pid={my_pid}, parent={_main_pid}). "
            f"Skipping parent cleanup, exiting immediately."
        )
        os._exit(1)

    logger.info(
        f"Signal {signum} in main process (pid={my_pid}). Running cleanup..."
    )
    print(f"\nReceived signal {signum}, cleaning up...", file=sys.stderr)
    if current_journal_sync:
        current_journal_sync.stop()  # Final sync before exit
    if current_heartbeat:
        current_heartbeat.stop()
    if current_report_uuid:
        notify_report_stopped(current_report_uuid)
    sys.exit(1)

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)

def run_garak_scan(garak_params):
    """Run the Garak scan with the provided parameters."""
    try:
        if isinstance(garak_params, str):
            params_list = shlex.split(garak_params)
        else:
            params_list = list(garak_params)

        sys.argv = ['garak'] + params_list

        print(f"Running Garak with parameters: {params_list}")

        from garak.__main__ import main
        exit_code = main()

        return exit_code if exit_code is not None else 0

    except ImportError as e:
        print(f"Error importing Garak: {e}", file=sys.stderr)
        print("Make sure Garak is installed and accessible in the Python path", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Error running Garak scan: {e}", file=sys.stderr)
        return 1

def notify_report_running(report_uuid, pid):
    """Notify Rails that the report is running with the given PID via PostgreSQL."""
    try:
        result = db_notify_running(report_uuid, pid)
        if result:
            print(f"Report {report_uuid} marked as running (pid={pid})")
        else:
            print(f"Warning: Failed to mark report {report_uuid} as running", file=sys.stderr)
        return result
    except Exception as e:
        print(f"Error notifying report running: {e}", file=sys.stderr)
        return False


def notify_report_ready(report_uuid, prefix=""):
    """Store report data in database and enqueue processing job."""
    try:
        result = db_notify_ready(report_uuid, prefix=prefix)
        if result:
            print(f"Report {report_uuid} data stored and job enqueued")
        else:
            print(f"Warning: Failed to store report {report_uuid} data", file=sys.stderr)
        return result
    except Exception as e:
        print(f"Error notifying report ready: {e}", file=sys.stderr)
        return False


def notify_report_ready_from_synced(report_uuid):
    """Enqueue processing job using already-synced raw_report_data."""
    try:
        result = db_notify_ready_from_synced(report_uuid)
        if result:
            print(f"Report {report_uuid} job enqueued (from synced data)")
        else:
            print(f"Warning: Failed to enqueue job for report {report_uuid}", file=sys.stderr)
        return result
    except Exception as e:
        print(f"Error notifying report ready from synced: {e}", file=sys.stderr)
        return False


def notify_report_stopped(report_uuid):
    """Clear PID from report in database (only if stored PID matches caller)."""
    try:
        result = db_notify_stopped(report_uuid)
        if result:
            print(f"Report {report_uuid} PID cleared")
        else:
            print(f"Report {report_uuid} PID not cleared (stored PID does not match this process)", file=sys.stderr)
        return result
    except Exception as e:
        print(f"Error notifying report stopped: {e}", file=sys.stderr)
        return False

def main():
    """Main function to parse arguments and run the Garak scan."""
    if len(sys.argv) < 2:
        print("Usage: python3 run_garak.py <report_uuid> [garak_params...]", file=sys.stderr)
        sys.exit(1)

    report_uuid = sys.argv[1]
    garak_params = sys.argv[2:]
    scan_id = os.environ.get('SCAN_ID', 'unknown')
    scan_name = os.environ.get('SCAN_NAME', 'unknown')
    target_id = os.environ.get('TARGET_ID', 'unknown')
    target_name = os.environ.get('TARGET_NAME', 'unknown')
    global current_report_uuid, current_heartbeat, current_journal_sync
    current_report_uuid = report_uuid

    # Get the current process PID
    current_pid = os.getpid()

    # Validation runs use "validation_" prefix and don't have a database report record
    # Skip heartbeat/DB notifications for validation to avoid premature termination
    is_validation = report_uuid.startswith("validation_")
    heartbeat = None
    journal_sync = None

    logger.info(f"Starting garak scan - Report: {report_uuid}, Scan: {scan_name}, "
                f"Target: {target_name}")

    if not is_validation:
        # Notify Rails that the report is running with PID (also sets initial heartbeat_at)
        notify_report_running(report_uuid, current_pid)

        heartbeat = HeartbeatThread(report_uuid)
        current_heartbeat = heartbeat
        heartbeat.start()

    try:
        if not is_validation:
            # Load existing partial JSONL for scan resumption
            # Inside try/finally so notify_report_stopped is called on failure
            prefix = load_existing_jsonl_prefix(report_uuid)

            # Start JournalSyncThread to periodically persist JSONL to database
            jsonl_path = REPORTS_PATH / f"{report_uuid}.report.jsonl"
            journal_sync = JournalSyncThread(report_uuid, jsonl_path, prefix=prefix)
            current_journal_sync = journal_sync
            journal_sync.start()

        exit_code = run_garak_scan(garak_params)
        logger.info(f"Garak scan completed - Report: {report_uuid}, "
                   f"Exit code: {exit_code}")
        print(f"Garak scan completed with exit code: {exit_code}")

        if not is_validation:
            # Stop journal sync BEFORE notify_report_ready_from_synced, because
            # notify_report_ready_from_synced calls cleanup_scan_files() which deletes
            # the JSONL file. If stop() runs after cleanup, _sync() reads an empty file
            # and overwrites raw_report_data with just the prefix (losing new probe data).
            sync_clean = True
            if journal_sync:
                sync_clean = journal_sync.stop()
                current_journal_sync = None
                journal_sync = None  # Prevent finally block from stopping again

            if sync_clean:
                # Use synced variant — JSONL already in raw_report_data, just add logs + enqueue job
                if not notify_report_ready_from_synced(report_uuid):
                    logger.error(f"Failed to enqueue ProcessReportJob for {report_uuid}")
                    exit_code = 1
            else:
                # Sync thread didn't stop cleanly — fall back to full disk read
                # to avoid processing stale/incomplete raw_report_data
                logger.warning(
                    f"JournalSync did not stop cleanly for {report_uuid}, "
                    f"falling back to full JSONL read from disk"
                )
                if not notify_report_ready(report_uuid, prefix=prefix):
                    logger.error(f"Failed to enqueue ProcessReportJob for {report_uuid}")
                    exit_code = 1

    except Exception as e:
        logger.error(f"Garak scan failed - Report: {report_uuid}, Error: {e}")
        print(f"Unexpected error: {e}", file=sys.stderr)

        exit_code = 1
    finally:
        # Stop journal sync if not already stopped (e.g., on exception path)
        if journal_sync:
            journal_sync.stop()
            current_journal_sync = None
        # Stop heartbeat before clearing PID
        if heartbeat:
            heartbeat.stop()
            current_heartbeat = None
        if not is_validation:
            notify_report_stopped(report_uuid)

    sys.exit(exit_code)


if __name__ == '__main__':
    main()
