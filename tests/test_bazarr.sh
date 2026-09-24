#!/usr/bin/env bash
# tests/test_bazarr.sh — verifica el fallo cerrado de download_secure (issue #4).
#
# DoD: "instalación con hash corrupto aborta sin ejecutar pip" → download_secure
# debe devolver ≠0 ante hash incorrecto (y no dejar el fichero), y 0 ante hash
# correcto. Usa una URL file:// local para no depender de red.
#
# NOTA: el caso de hash incorrecto reintenta 3 veces (con sleep), por lo que el
# test tarda ~15 s.
#
# Uso: bash tests/test_bazarr.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export LOG_FILE=/dev/null
source "${REPO_ROOT}/lib/utils.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

printf 'bazarr test payload\n' > "${TMP}/payload.bin"
HASH="$(sha256sum "${TMP}/payload.bin" | awk '{print $1}')"
WRONG_HASH="0000000000000000000000000000000000000000000000000000000000000000"

fail=0

# hash correcto → 0 (y deja el fichero)
rc=0
download_secure "file://${TMP}/payload.bin" "${TMP}/ok.bin" "${HASH}" >/dev/null 2>&1 || rc=$?
if [[ ${rc} -eq 0 && -f "${TMP}/ok.bin" ]]; then
    echo "OK   hash correcto -> éxito (rc=0)"
else
    echo "FAIL hash correcto no devuelve 0 (rc=${rc})"
    fail=1
fi

# hash incorrecto → ≠0 (fallo cerrado) y no deja fichero
rc=0
download_secure "file://${TMP}/payload.bin" "${TMP}/bad.bin" "${WRONG_HASH}" >/dev/null 2>&1 || rc=$?
if [[ ${rc} -ne 0 && ! -f "${TMP}/bad.bin" ]]; then
    echo "OK   hash incorrecto -> fallo cerrado (rc=${rc}, sin fichero)"
else
    echo "FAIL hash incorrecto no falla cerrado (rc=${rc})"
    fail=1
fi

echo ""
if [[ "${fail}" -eq 0 ]]; then
    echo "PASS: todos los asserts."
else
    echo "FAIL: hay asserts en rojo."
fi
exit "${fail}"
