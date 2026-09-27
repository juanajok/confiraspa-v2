#!/usr/bin/env bash
# spike/test_spike.sh — pruebas del executor + API (spike v2, endurecido).
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SPIKE_DIR"

export CONFIRASPA_EXECUTOR_SOCKET="$(mktemp -u /tmp/confiraspa-executor.XXXXXX.sock)"
export CONFIRASPA_JOB_DB="$(mktemp -u /tmp/confiraspa-jobs.XXXXXX.db)"
export CONFIRASPA_API_PORT="18080"
export CONFIRASPA_EXEC_TIMEOUT="3"      # para poder probar el timeout rápido
export CONFIRASPA_CONN_TIMEOUT="2"      # para probar cliente que no termina

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

python3 executor.py & EXEC_PID=$!
python3 api.py & API_PID=$!
sleep 1.5

# --- 1. Permisos del socket (0660) ---
[ "$(stat -c '%a' "$SOCK")" = "660" ] && pass "socket con permisos 0660" || failm "permisos = $(stat -c '%a' "$SOCK")"

# --- 2. app_id desconocido → 404 ---
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/apps/foo/install")
[ "$code" = "404" ] && pass "app_id desconocido → 404" || failm "app desconocido devolvió $code"

# --- 3. Instalación (catálogo) → success ---
jid=$(curl -s -X POST "$BASE/api/v1/apps/plex/install" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 3
st=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')
[ "$st" = "success" ] && pass "app.install(plex) → success" || failm "install quedó '$st'"

# --- 4. Redacción de secretos ---
jid=$(curl -s -X POST "$BASE/api/v1/echo" -d '{"message":"hola password=supersecreto https://u:pass@host/x"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
if echo "$out" | grep -q 'REDACTED' && ! echo "$out" | grep -q 'supersecreto' && ! echo "$out" | grep -q 'pass@host'; then
    pass "salida con secretos redactados (password + URL)"
else
    failm "redacción falló: $out"
fi

# --- 5. Los params sensibles NO se persisten ni se devuelven ---
jid=$(curl -s -X POST "$BASE/api/v1/echo" -d '{"message":"supersecreto-no-persistir"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
params=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["params"]))')
if ! echo "$params" | grep -q 'supersecreto-no-persistir'; then pass "params sensibles no persistidos"; else failm "params filtrados: $params"; fi

# --- 6. Body HTTP demasiado grande → 413 ---
BIG=$(python3 -c 'print("x"*70000)')
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/echo" -d "{\"message\":\"$BIG\"}")
[ "$code" = "413" ] && pass "body HTTP enorme → 413" || failm "body enorme devolvió $code"

# --- 7. Truncado de salida masiva (op 'spew' genera 200 KB) ---
jid=$(curl -s -X POST "$BASE/api/v1/spew" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
if echo "$out" | grep -q 'truncado'; then pass "salida masiva truncada (acotada desde el origen)"; else failm "no truncó"; fi

# --- 8. Parámetros extra → rechazado ---
jid=$(curl -s -X POST "$BASE/api/v1/echo" -d '{"message":"hi","extra":"x"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
echo "$out" | grep -q 'no permitidos' && pass "parámetros extra rechazados" || failm "extra: $out"

# --- 9. Tipo incorrecto → rechazado ---
jid=$(curl -s -X POST "$BASE/api/v1/echo" -d '{"message":123}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
echo "$out" | grep -q 'debe ser str' && pass "tipo incorrecto rechazado" || failm "tipo: $out"

# --- 10. Operación desconocida (socket directo) → rechazada ---
resp=$(python3 - "$SOCK" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1])
s.sendall((json.dumps({"job_id":"j_x","operation":"rm","params":{}})+"\n").encode())
d=b""
while not d.endswith(b"\n"):
    c=s.recv(4096)
    if not c: break
    d+=c
s.close(); print(d.decode())
PY
)
echo "$resp" | grep -q 'desconocida' && pass "operación desconocida rechazada" || failm "op desconocida: $resp"

# --- 11. Límite de concurrencia ---
jid1=$(curl -s -X POST "$BASE/api/v1/apps/plex/install" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
jid2=$(curl -s -X POST "$BASE/api/v1/apps/plex/install" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
out2=$(curl -s "$BASE/api/v1/jobs/$jid2" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
echo "$out2" | grep -q 'concurrencia' && pass "límite de concurrencia" || failm "concurrencia: $out2"
sleep 3

# --- 12. Fallo real (op 'fail') → job failed con exit code ---
jid=$(curl -s -X POST "$BASE/api/v1/fail" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 1
rc=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["exit_code"])')
[ "$rc" != "0" ] && pass "op fail → job failed (exit=$rc)" || failm "fail no falló: exit=$rc"

# --- 13. Timeout de ejecución (op 'slow', EXEC_TIMEOUT=3) ---
jid=$(curl -s -X POST "$BASE/api/v1/slow" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job_id"])')
sleep 4
out=$(curl -s "$BASE/api/v1/jobs/$jid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["output"])')
echo "$out" | grep -q 'timeout' && pass "timeout de ejecución aplicado" || failm "timeout no aplicado: $out"

# --- 14. Cliente que no termina la línea (socket, CONN_TIMEOUT=2) ---
resp=$(python3 - "$SOCK" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1])
s.sendall(b'{"job_id":"j_partial"')   # media línea, nunca el cierre
time.sleep(3)                          # espera más que CONN_TIMEOUT
try:
    d = s.recv(4096)
except Exception:
    d = b''
s.close()
print("cerrado" if not d else "recibio:" + d.decode()[:40])
PY
)
if echo "$resp" | grep -q 'cerrado'; then pass "cliente que no termina no bloquea (se cierra)"; else failm "cliente colgado: $resp"; fi

# --- 15. Reinicio: 'running' y 'pending' obsoletos → failed ---
python3 - "$CONFIRASPA_JOB_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, operation TEXT, params TEXT, status TEXT, exit_code INTEGER, output TEXT, created_at TEXT, finished_at TEXT)")
c.execute("INSERT INTO jobs (id, operation, params, status, created_at) VALUES ('j_run','app.install','{}','running',datetime('now'))")
c.execute("INSERT INTO jobs (id, operation, params, status, created_at) VALUES ('j_pend','app.install','{}','pending',datetime('now','-1 day'))")
c.commit(); c.close()
PY
kill "$EXEC_PID" 2>/dev/null || true
python3 executor.py & EXEC_PID=$!
sleep 1
st_run=$(python3 - "$CONFIRASPA_JOB_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); print(c.execute("SELECT status FROM jobs WHERE id='j_run'").fetchone()[0]); c.close()
PY
)
st_pend=$(python3 - "$CONFIRASPA_JOB_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); print(c.execute("SELECT status FROM jobs WHERE id='j_pend'").fetchone()[0]); c.close()
PY
)
[ "$st_run" = "failed" ] && pass "job 'running' obsoleto → failed" || failm "running quedó '$st_run'"
[ "$st_pend" = "failed" ] && pass "job 'pending' huérfano → failed" || failm "pending quedó '$st_pend'"

echo ""
if [ "$fail" -eq 0 ]; then echo "PASS: todos los asserts."; else echo "FAIL: hay asserts en rojo."; fi
exit "$fail"
