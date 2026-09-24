#!/usr/bin/env bash
# tests/test_swap_zswap.sh — verifica el helper swap_size_a_mb (issue #7).
#
# Extrae la función real del script y valida la conversión a MB, incluidos los
# casos con cero a la izquierda ("08G") que antes abortaban por octal inválido.
#
# NOTA: la lógica de swap (swapoff/mkswap/swapon) y el guard de disco lleno en
# main() requieren root y no se testean aquí; el guard es verificable en la RPi.
#
# Uso: bash tests/test_swap_zswap.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

helper="$(awk '/^swap_size_a_mb\(\)/,/^}/' "${REPO_ROOT}/scripts/40-maintenance/configurar_swap_zswap.sh")"
eval "$helper"

fail=0
check_eq() {  # check_eq <esperado> <real> <descripción>
    if [[ "$2" == "$1" ]]; then
        echo "OK   $3 ($2)"
    else
        echo "FAIL $3 (esperado $1, obtenido $2)"
        fail=1
    fi
}

check_eq 4096 "$(swap_size_a_mb 4G)"   "4G -> MB"
check_eq 512  "$(swap_size_a_mb 512M)" "512M -> MB"
check_eq 2048 "$(swap_size_a_mb 2G)"   "2G -> MB"
check_eq 128  "$(swap_size_a_mb 128M)" "128M -> MB"
check_eq 8192 "$(swap_size_a_mb 08G)"  "08G -> MB (sin error octal)"
check_eq 8    "$(swap_size_a_mb 08M)"  "08M -> MB (sin error octal)"
check_eq 0    "$(swap_size_a_mb xyz)"  "inválido -> 0"

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: todos los asserts."
else
    echo "FAIL: hay asserts en rojo."
fi
exit "$fail"
