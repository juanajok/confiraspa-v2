#!/usr/bin/env bash
# spike/test_spike.sh — pruebas negativas del executor + API (spike MVP).
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SPIKE_DIR"

export CONFIRASPA_EXECUTOR_SOCKET="$(mktemp -u /tmp/confiraspa-executor.XXXXXX.sock)"
export CONFIRASPA_JOB_DB="$(mktemp -u /tmp/confiraspa-jobs.XXXXXX.db)"
export CONFIRASPA_API_PORT="18080"

PORT="$CONFIRASPA_API_PORT"
SOCK="$CONFIRASPA_EXECUTOR_SOCKET"
BASE="http://127.0.0.1:$PORT"

fail=0
pass() { echo "OK   $1"; }
failm() { echo "FAIL $1"; fail=1; }

cleanup() {
    kill "$API_PID" "$EXEC_PID" 2>/dev/null || true
    rm -f "$SOCK" "$CONFIRASPA_JOB_DB"
}
trap cleanup EXIT

# Arrancar executor y API
python3 executor.py & EXEC_PID=$!
python3 api.py & API_PID=$!
sleep 1.5

# --- 1. Permisos del socket (0660) ---
if [ "$(stat -c '%a' "$SOCK")" = "660" ]; then pass "socket con permisos 0660"; else failm "permisos socket = $(stat -c '%a' "$SOCK")"; fi

# --- 2. app_id desconocido → 404 ---
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/apps/foo/install")
[ "$code" = "404" ] && pass "app_id desconocido → 404" || failm "app desconocido devolvió $code"

# --- 3. Instalación real (catálogo) → job success ---
jid=$(curl -s -X POST "$BASE/api/v1/apps/plex/install" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 3  # el stub tarda 2s
st=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')
[ "$st" = "success" ] && pass "app.install(plex) → job success" || failm "install quedó '$st'"

# --- 4. Redacción de secretos ---
jid=$(curl -s -X POST "$BASE/api/v1/echo" -d '{"message":"hola password=supersecreto token=abc123"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
if echo "$out" | grep -q 'REDACTED' && ! echo "$out" | grep -q 'supersecreto'; then
    pass "salida con secretos redactados"
else
    failm "redacción falló: $out"
fi

# --- 5. Límite de tamaño de salida ---
BIG=$(python3 -c 'print("x"*70000)')
jid=$(curl -s -X POST "$BASE/api/v1/echo" -d "{\"message\":\"$BIG\"}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
if echo "$out" | grep -q 'truncado'; then pass "salida truncada"; else failm "no truncó"; fi

# --- 6. Parámetros extra → rechazado ---
jid=$(curl -s -X POST "$BASE/api/v1/echo" -d '{"message":"hi","extra":"x"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
if echo "$out" | grep -q 'no permitidos'; then pass "parámetros extra rechazados"; else failm "extra no rechazado: $out"; fi

# --- 7. Tipo incorrecto → rechazado ---
jid=$(curl -s -X POST "$BASE/api/v1/echo" -d '{"message":123}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
if echo "$out" | grep -q 'debe ser str'; then pass "tipo incorrecto rechazado"; else failm "tipo no rechazado: $out"; fi

# --- 8. Operación desconocida (socket directo, JSON crudo) → rechazada ---
resp=$(python3 - "$SOCK" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall((json.dumps({"job_id": "j_x", "operation": "rm", "params": {}}) + "\n").encode())
data = b""
while not data.endswith(b"\n"):
    c = s.recv(4096)
    if not c:
        break
    data += c
s.close()
print(data.decode())
PY
)
if echo "$resp" | grep -q 'desconocida'; then pass "operación desconocida rechazada"; else failm "op desconocida: $resp"; fi

# --- 9. Concurrencia: segundo install mientras corre el primero → rechazado ---
jid1=$(curl -s -X POST "$BASE/api/v1/apps/plex/install" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
jid2=$(curl -s -X POST "$BASE/api/v1/apps/plex/install" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out2=$(curl -s "$BASE/api/v1/jobs/$jid2" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
if echo "$out2" | grep -q 'concurrencia'; then pass "límite de concurrencia aplicado"; else failm "concurrencia no aplicada: $out2"; fi
sleep 3  # dejar terminar jid1

# --- 10. Job persistente + reinicio marca 'running' obsoleto como failed ---
# (mark_stale_running_failed se ejecuta al arrancar el executor)
python3 - "$CONFIRASPA_JOB_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, operation TEXT, params TEXT, status TEXT, exit_code INTEGER, output TEXT, created_at TEXT, finished_at TEXT)")
c.execute("INSERT INTO jobs (id, operation, params, status, created_at) VALUES ('j_stale','app.install','{}','running',datetime('now'))")
c.commit(); c.close()
PY
kill "$EXEC_PID" 2>/dev/null || true
python3 executor.py & EXEC_PID=$!
sleep 1
st=$(python3 - "$CONFIRASPA_JOB_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("SELECT status FROM jobs WHERE id='j_stale'").fetchone()[0])
c.close()
PY
)
[ "$st" = "failed" ] && pass "job 'running' obsoleto marcado failed tras reinicio" || failm "stale running quedó '$st'"

echo ""
if [ "$fail" -eq 0 ]; then echo "PASS: todos los asserts."; else echo "FAIL: hay asserts en rojo."; fi
exit "$fail"
