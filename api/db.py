"""Optional PostgreSQL storage for the API: every prediction is saved as a row.

The database is optional: with DB_HOST unset (or the database down) the API
keeps answering predictions and just reports the database status.
"""
import logging
import os
import threading

import psycopg2

log = logging.getLogger(__name__)

DB_HOST = os.environ.get("DB_HOST", "")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "fashion")
DB_USER = os.environ.get("DB_USER", "fashion")
DB_PASSWORD_FILE = os.environ.get("DB_PASSWORD_FILE", "/run/secrets/db_password")

SCHEMA = """
CREATE TABLE IF NOT EXISTS predictions (
    id          SERIAL PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    source      VARCHAR(10) NOT NULL,          -- 'sample' (test image) or 'upload'
    test_index  INTEGER,
    predicted   VARCHAR(20) NOT NULL,
    true_label  VARCHAR(20),                   -- only known for test images
    confidence  REAL NOT NULL,
    api_host    VARCHAR(64)
)
"""

_schema_ready = False
_lock = threading.Lock()


def enabled():
    return bool(DB_HOST)


def _password():
    # podman secret (file) wins over a plain env var
    if os.path.exists(DB_PASSWORD_FILE):
        with open(DB_PASSWORD_FILE) as f:
            return f.read().strip()
    return os.environ.get("DB_PASSWORD", "")


def _connect():
    global _schema_ready
    conn = psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
                            password=_password(), connect_timeout=3)
    if not _schema_ready:
        with _lock, conn, conn.cursor() as cur:
            cur.execute(SCHEMA)
        _schema_ready = True
    return conn


def status():
    if not enabled():
        return "disabled (DB_HOST not set)"
    try:
        conn = _connect()
        conn.close()
        return "ok"
    except Exception as e:
        return f"error: {str(e).strip().splitlines()[0]}"


def save(rows):
    """rows: list of dicts with source, predicted, confidence, [true_label, test_index]."""
    if not enabled() or not rows:
        return False
    try:
        conn = _connect()
        with conn, conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO predictions (source, test_index, predicted, true_label, confidence, api_host) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                [(r["source"], r.get("test_index"), r["predicted"], r.get("true_label"),
                  r["confidence"], os.environ.get("HOSTNAME", "")) for r in rows])
        conn.close()
        return True
    except Exception as e:
        log.warning("could not save predictions: %s", e)
        return False


def history(limit=20):
    conn = _connect()
    with conn, conn.cursor() as cur:
        cur.execute("SELECT id, created_at, source, test_index, predicted, true_label, confidence "
                    "FROM predictions ORDER BY id DESC LIMIT %s", (limit,))
        cols = [c.name for c in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    conn.close()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat(timespec="seconds")
    return rows


def stats():
    conn = _connect()
    with conn, conn.cursor() as cur:
        cur.execute("SELECT count(*), "
                    "count(*) FILTER (WHERE source = 'upload'), "
                    "count(*) FILTER (WHERE true_label IS NOT NULL), "
                    "count(*) FILTER (WHERE true_label = predicted) FROM predictions")
        total, uploads, labelled, correct = cur.fetchone()
        cur.execute("SELECT predicted, count(*) FROM predictions GROUP BY predicted ORDER BY 2 DESC")
        per_class = dict(cur.fetchall())
    conn.close()
    return {"total": total, "uploads": uploads, "labelled": labelled, "correct": correct,
            "accuracy": round(correct / labelled, 4) if labelled else None,
            "per_predicted_class": per_class}
