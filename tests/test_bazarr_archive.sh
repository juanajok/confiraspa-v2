#!/usr/bin/env bash
# tests/test_bazarr_archive.sh — valida validate_bazarr_archive (issue #4).
#
# Extrae la función real de bazarr.sh y la prueba contra ZIPs reales:
#   - ZIP válido (bazarr.py + requirements.txt)          -> aceptado (0)
#   - ZIP con entrada '../evil'                           -> rechazado (1)
#   - ZIP con ruta absoluta                               -> rechazado (1)
#   - ZIP con symlink                                     -> rechazado (1)
#   - ZIP sin requirements.txt                            -> rechazado (1)
#
# Uso: bash tests/test_bazarr_archive.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for c in zip unzip python3; do command -v "$c" >/dev/null 2>&1 || { echo "SKIP: '$c' no disponible"; exit 0; }; done

log_error() { :; }  # stub mínimo (solo nos importa el código de retorno)

fn="$(awk '/^validate_bazarr_archive\(\)/,/^}/' "${REPO_ROOT}/scripts/30-services/bazarr.sh")"
eval "$fn"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail=0

check_rc() {  # check_rc <esperado 0|1> <desc> <comando...>
    local expected="$1" desc="$2"; shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    [[ ${rc} -ne 0 ]] && rc=1
    if [[ ${rc} -eq ${expected} ]]; then
        echo "OK   $desc"
    else
        echo "FAIL $desc (esperado ${expected}, rc=${rc})"
        fail=1
    fi
}

# 1. ZIP válido
mkdir -p "$TMP/good"
printf 'x\n' > "$TMP/good/bazarr.py"
printf 'flask==1.0\n' > "$TMP/good/requirements.txt"
(cd "$TMP/good" && zip -q "$TMP/good.zip" bazarr.py requirements.txt) >/dev/null 2>&1
check_rc 0 "ZIP válido aceptado" validate_bazarr_archive "$TMP/good.zip"

# 2. ZIP con entrada '../evil' (vía python, que permite nombres arbitrarios)
python3 - "$TMP/trav.zip" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w')
z.writestr('../evil', 'x')
z.writestr('bazarr.py', 'x')
z.writestr('requirements.txt', 'x')
z.close()
PY
check_rc 1 "ZIP con '../evil' rechazado" validate_bazarr_archive "$TMP/trav.zip"

# 3. ZIP con ruta absoluta
python3 - "$TMP/abs.zip" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w')
z.writestr('/etc/pwned', 'x')
z.writestr('bazarr.py', 'x')
z.writestr('requirements.txt', 'x')
z.close()
PY
check_rc 1 "ZIP con ruta absoluta rechazado" validate_bazarr_archive "$TMP/abs.zip"

# 4. ZIP con symlink
mkdir -p "$TMP/sym"
ln -s /etc/passwd "$TMP/sym/bazarr.py"
printf 'x\n' > "$TMP/sym/requirements.txt"
(cd "$TMP/sym" && zip -qy "$TMP/sym.zip" bazarr.py requirements.txt) >/dev/null 2>&1
check_rc 1 "ZIP con symlink rechazado" validate_bazarr_archive "$TMP/sym.zip"

# 5. ZIP sin requirements.txt
mkdir -p "$TMP/missing"
printf 'x\n' > "$TMP/missing/bazarr.py"
(cd "$TMP/missing" && zip -q "$TMP/missing.zip" bazarr.py) >/dev/null 2>&1
check_rc 1 "ZIP sin requirements.txt rechazado" validate_bazarr_archive "$TMP/missing.zip"

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: todos los asserts."
else
    echo "FAIL: hay asserts en rojo."
fi
exit "$fail"
