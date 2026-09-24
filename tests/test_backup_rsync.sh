#!/usr/bin/env bash
# tests/test_backup_rsync.sh — test funcional de backup_rsync.sh (issue #5).
#
# No requiere root: carga las funciones reales del script (todo lo anterior a
# `main()`) y stubea el entorno (findmnt, execute_cmd, check_disk_space,
# is_source_safe). Verifica:
#   1. run_backup_job devuelve 0 (éxito), 1 (fallo), 2 (skip).
#   2. validate_config_json devuelve 1 ante JSON corrupto y 0 ante JSON válido.
#
# Uso: bash tests/test_backup_rsync.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/40-maintenance/backup_rsync.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Extraer definiciones (todo antes de 'main()')
awk '/^main\(\) *\{/{exit} {print}' "${SCRIPT}" > "${TMP}/funcs.sh"

# Entorno mínimo (LOG_FILE=/dev/null para no escribir en /var/log)
export REPO_ROOT
export LOG_FILE=/dev/null
source "${TMP}/funcs.sh"

# Stubs que controlan el entorno (se resuelven en tiempo de llamada)
findmnt()          { echo "${FAKE_MOUNT:-/media/Backup}"; }
check_disk_space() { return 0; }
is_source_safe()   { return 0; }
execute_cmd() {
    local cmd="${1-}"
    case "$cmd" in
        rsync*) return "${RSYNC_RESULT:-0}" ;;
        *)      return 0 ;;
    esac
}

fail=0
assert_rc() {  # assert_rc <esperado> <real> <descripción>
    if [[ "$2" -eq "$1" ]]; then
        echo "OK   $3 (rc=$2)"
    else
        echo "FAIL $3 (esperado $1, obtenido $2)"
        fail=1
    fi
}

run_rc() { local rc=0; "$@" || rc=$?; echo "$rc"; }

# --- 1. run_backup_job: máquina de códigos de salida ---
RSYNC_RESULT=0
assert_rc 0 "$(run_rc run_backup_job t /s/src /media/Backup/d)" "rsync OK            -> 0"
RSYNC_RESULT=1
assert_rc 1 "$(run_rc run_backup_job t /s/src /media/Backup/d)" "rsync falla         -> 1"
FAKE_MOUNT=/
assert_rc 2 "$(run_rc run_backup_job t /s/src /media/Backup/d)" "destino en rootfs   -> 2 (skip)"

# --- 2. validate_config_json: fallo cerrado ante JSON corrupto ---
echo '{"jobs": [ {bad' > "${TMP}/corrupt.json"
assert_rc 1 "$(run_rc validate_config_json "${TMP}/corrupt.json")" "JSON corrupto       -> 1"
assert_rc 0 "$(run_rc validate_config_json "${REPO_ROOT}/configs/static/backup_rsync.json")" "JSON válido         -> 0"

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: todos los asserts."
else
    echo "FAIL: hay asserts en rojo."
fi
exit "$fail"
