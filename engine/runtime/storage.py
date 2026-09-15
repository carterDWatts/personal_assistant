"""Bound harness diagnostics without touching conversations or credentials."""
from contextlib import closing
import sqlite3
import time
import shutil


def trim_logs(state, budget=32 * 1024 * 1024, seconds=5):
    deadline = time.monotonic() + seconds
    for path in state.glob('logs_*.sqlite'):
        if path.is_symlink() or path.stat().st_size <= budget:
            continue
        try:
            with closing(sqlite3.connect(f'file:{path}?mode=rw', uri=True, timeout=1)) as db:
                page_size = db.execute('pragma page_size').fetchone()[0]
                while time.monotonic() < deadline:
                    pages = db.execute('pragma page_count').fetchone()[0]
                    free = db.execute('pragma freelist_count').fetchone()[0]
                    if (pages - free) * page_size > budget:
                        removed = db.execute('delete from logs where id in (select id from logs order by id limit 1000)').rowcount
                        db.commit()
                        if not removed: break
                    elif not free:
                        break
                    db.execute('pragma wal_checkpoint(truncate)').fetchall()
                    db.execute('pragma incremental_vacuum(2048)').fetchall()
                    db.execute('pragma wal_checkpoint(truncate)').fetchall()
        except (sqlite3.Error, OSError):
            # Another harness can hold a write lock; the next maintenance pass retries.
            continue


class StorageFullError(RuntimeError):
    def __init__(self):
        super().__init__('The host is running low on storage. Your saved conversation is safe, but replies are paused until space is available.')


def require_space(path, reserve=64 * 1024 * 1024):
    """Leave room for SQLite journals instead of letting the harness fail mid-write."""
    while not path.exists() and path != path.parent:
        path = path.parent
    if shutil.disk_usage(path).free < reserve:
        raise StorageFullError()
