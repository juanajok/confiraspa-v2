"""Store de jobs compartido (SQLite) para el spike.

Jobs persistentes: sobreviven a reinicios. Estados: pending|running|success|failed.

Regla de secretos: NUNCA se persisten parámetros sensibles. `summarize()` filtra
qué campos de cada operación son públicos y pueden guardarse.
"""
import json
import os
import sqlite3

JOB_DB = os.environ.get("CONFIRASPA_JOB_DB", "/tmp/confiraspa-jobs.db")
STALE_PENDING_MINUTES = 15  # jobs 'pending' huérfanos más viejos → failed

# Campos públicos por operación (los demás no se persisten jamás).
PUBLIC_PARAMS = {
    "echo": set(),            # 'message' puede ser sensible: no se guarda
    "app.install": {"app_id"},
    "fail": set(),
    "slow": set(),
    "spew": set(),
}

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


def summarize(operation, params):
    """Devuelve solo los campos públicos de la operación (nunca secretos)."""
    return {k: params[k] for k in PUBLIC_PARAMS.get(operation, set()) if k in params}


def _conn():
    c = sqlite3.connect(JOB_DB)
    c.execute(_SCHEMA)
    c.commit()
    return c


def create_job(job_id, operation, params_summary):
    c = _conn()
    c.execute(
        "INSERT INTO jobs (id, operation, params, status, created_at) VALUES (?,?,?,?,datetime('now'))",
        (job_id, operation, json.dumps(params_summary), "pending"),
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


def mark_stale_jobs_failed():
    """Al arrancar el executor:
    - 'running' → failed (interrumpido por reinicio). Nota: no garantiza que el
      proceso hijo muriera; solo marca el job como no confirmado.
    - 'pending' más viejos que STALE_PENDING_MINUTES → failed (huérfanos de una
      API que murió sin enviar al executor).
    """
    c = _conn()
    c.execute(
        "UPDATE jobs SET status='failed', exit_code=137, output='interrumpido por reinicio del executor (estado no confirmado)', finished_at=datetime('now') WHERE status='running'"
    )
    c.execute(
        "UPDATE jobs SET status='failed', exit_code=137, output='huérfano: la API no completó el envío', finished_at=datetime('now') WHERE status='pending' AND created_at < datetime('now', ?)",
        (f"-{STALE_PENDING_MINUTES} minutes",),
    )
    c.commit()
    c.close()
