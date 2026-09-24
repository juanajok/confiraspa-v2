#!/usr/bin/env bash
# tests/test_transmission.sh — verifica el render de la plantilla de Transmission (issue #6).
#
# No requiere root: renderiza configs/static/templates/transmission.json con
# envsubst (las mismas variables y whitelist que usa transmission.sh) y valida:
#   - rpc-port es el puerto WEB (9091), no el P2P — el fix del bug 14.1.
#   - peer-port es el puerto P2P (51413).
#   - ambos son números JSON (no strings).
#   - rpc-authentication-required=true (sin esto la contraseña se ignora).
#   - rpc-whitelist habilitada y cubre RFC1918 completo + Tailscale.
#   - un puerto no numérico produce JSON inválido (motivo del guard).
#
# NOTA: es un test de HUMO del render. El guard numérico en sí vive en el top-level
# de transmission.sh (que ejecuta validate_root y no puede correr aquí sin stubs);
# aquí se verifica su CONSECUENCIA (JSON inválido), no el bucle en sí.
#
# Uso: bash tests/test_transmission.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="${REPO_ROOT}/configs/static/templates/transmission.json"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export DIR_TORRENTS=/media/Descargas/torrents/completos
export DIR_INCOMPLETE=/media/Descargas/torrents/temp
export TRANSMISSION_USER=admin
export TRANSMISSION_PASS='FAKE-TEST-ONLY'
export TRANSMISSION_PEER_PORT=51413
export TRANSMISSION_WEB_PORT=9091

WHITELIST='${DIR_TORRENTS} ${DIR_INCOMPLETE} ${TRANSMISSION_USER} ${TRANSMISSION_PASS} ${TRANSMISSION_PEER_PORT} ${TRANSMISSION_WEB_PORT}'

envsubst "$WHITELIST" < "$TPL" > "$TMP/rendered.json"

fail=0
check() {  # check <descripción> <comando...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "OK   $desc"
    else
        echo "FAIL $desc"
        fail=1
    fi
}

check "JSON render válido"            jq empty "$TMP/rendered.json"
check "rpc-port = 9091 (número)"      jq -e '.["rpc-port"] == 9091 and (.["rpc-port"]|type)=="number"' "$TMP/rendered.json"
check "peer-port = 51413 (número)"    jq -e '.["peer-port"] == 51413 and (.["peer-port"]|type)=="number"' "$TMP/rendered.json"
check "rpc-authentication-required"   jq -e '.["rpc-authentication-required"] == true' "$TMP/rendered.json"
check "rpc-whitelist habilitada"      jq -e '.["rpc-whitelist-enabled"] == true' "$TMP/rendered.json"
check "whitelist 192.168 + 10 + Tailscale" jq -e '.["rpc-whitelist"] | contains("192.168.*.*") and contains("10.*.*.*") and contains("100.*.*.*")' "$TMP/rendered.json"

# RFC1918 172.16/12 = 172.16.*.* … 172.31.*.* (Transmission solo entiende wildcards, no CIDR).
wl_ok=1
for n in $(seq 16 31); do
    jq -e --arg p "172.$n.*.*" '.["rpc-whitelist"] | contains($p)' "$TMP/rendered.json" >/dev/null 2>&1 || { wl_ok=0; echo "  falta 172.$n.*.*"; }
done
if [[ "$wl_ok" -eq 1 ]]; then
    echo "OK   whitelist cubre 172.16/12 completo (16 entradas)"
else
    echo "FAIL whitelist 172.16/12 incompleta"
    fail=1
fi

# Consecuencia que motiva el guard numérico: puerto no numérico => JSON inválido.
TRANSMISSION_WEB_PORT=abc envsubst "$WHITELIST" < "$TPL" > "$TMP/bad.json"
check "puerto no numérico => JSON inválido (motivo del guard)" bash -c '! jq empty "$1"' _ "$TMP/bad.json"

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: todos los asserts."
else
    echo "FAIL: hay asserts en rojo."
fi
exit "$fail"
