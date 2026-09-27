"""Store de jobs compartido (SQLite) para el spike.

Jobs persistentes: sobreviven a reinicios. Estados: pending|running|success|failed.
"""
import json
import os
import sqlite3

JOB_DB = os.environ.get("CONFIRASPA_JOB_DB", "/tmp/confiraspa-jobs.db")

_SCHEMA = """CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    operation TEXT NOT NULL,
    params TEXT NOT NULL,
    status TEXT NOT NULL,
    exit_code INTEGER,
    output TEXT,
    created_at TEXT NOT NULL,
    finished_at TEXT
)"""


def _conn():
    c = sqlite3.connect(JOB_DB)
    c.execute(_SCHEMA)
    c.commit()
    return c


def create_job(job_id, operation, params):
    c = _conn()
    c.execute(
        "INSERT INTO jobs (id, operation, params, status, created_at) VALUES (?,?,?,?,datetime('now'))",
        (job_id, operation, json.dumps(params), "pending"),
    )
    c.commit()
    c.close()


def update_job(job_id, **fields):
    c = _conn()
    setq = ", ".join(f"{k}=?" for k in fields)
    c.execute(f"UPDATE jobs SET {setq} WHERE id=?", (*fields.values(), job_id))
    c.commit()
    c.close()


def get_job(job_id):
    c = _conn()
    row = c.execute(
        "SELECT id,operation,params,status,exit_code,output,created_at,finished_at FROM jobs WHERE id=?",
        (job_id,),
    ).fetchone()
    c.close()
    if not row:
        return None
    keys = ("id", "operation", "params", "status", "exit_code", "output", "created_at", "finished_at")
    d = dict(zip(keys, row))
    if d["params"]:
        d["params"] = json.loads(d["params"])
    return d


def mark_stale_running_failed():
    """Al arrancar, marca como 'failed' los jobs que quedaron 'running' (reinicio)."""
    c = _conn()
    c.execute(
        "UPDATE jobs SET status='failed', exit_code=137, output='interrumpido por reinicio del executor', finished_at=datetime('now') WHERE status='running'"
    )
    c.commit()
    c.close()
