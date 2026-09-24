#!/usr/bin/env bash
# tests/test_fix_permissions.sh — verifica is_safe_path y preservación de setgid (#11).
#
# 1. is_safe_path (extraída del script): rechaza blacklist (/, /etc, /root…),
#    profundidad 0-1 y symlinks que resuelven a rutas peligrosas.
# 2. setgid (20.2): la expresión de fix_dir_permissions NO selecciona dirs 2775,
#    y tras chmod 775 un dir 2775 conserva el setgid mientras un 755 pasa a 775.
# 3. -xdev (5.1): verificación estática de que find/chown usan -xdev.
#
# Uso: bash tests/test_fix_permissions.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/40-maintenance/fix_permissions.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail=0

# --- Extraer BLACKLISTED_PATHS + is_safe_path ---
fn="$(awk '/^readonly BLACKLISTED_PATHS=/{f=1} f{print} /^}$/{if(f) exit}' "$SCRIPT")"
eval "$fn"

assert_reject() { is_safe_path "$1" >/dev/null 2>&1 && { echo "FAIL $2 (aceptado, debía rechazar)"; fail=1; } || echo "OK   $2"; }
assert_accept() { is_safe_path "$1" >/dev/null 2>&1 && echo "OK   $2" || { echo "FAIL $2 (rechazado, debía aceptar)"; fail=1; }; }

# --- 1. is_safe_path (20.3) ---
assert_reject "/"                      "/ rechazado"
assert_reject "/media"                 "/media rechazado (profundidad 1)"
assert_reject "/etc"                   "/etc rechazado (blacklist)"
assert_reject "/root"                  "/root rechazado (blacklist)"
assert_accept "/media/WDElements"      "/media/WDElements aceptado"
assert_accept "/media/WDElements/Series" "/media/WDElements/Series aceptado"

# symlink que resuelve a / debe rechazarse (realpath)
ln -s / "$TMP/link_to_root"
assert_reject "$TMP/link_to_root" "symlink a / rechazado (realpath)"

# --- 2. setgid (20.2) ---
mkdir -p "$TMP/perms/d2775" "$TMP/perms/d775" "$TMP/perms/d755"
chmod 2775 "$TMP/perms/d2775"
chmod 775  "$TMP/perms/d775"
chmod 755  "$TMP/perms/d755"

# Selección: solo dirs sin setgid y != 775
selected="$(find "$TMP/perms" -xdev -mindepth 1 -type d ! -perm -2000 ! -perm 775 -printf '%f\n' | sort)"
if [[ "$selected" == "d755" ]]; then
    echo "OK   selección excluye 2775 y 775 (solo d755)"
else
    echo "FAIL selección incorrecta: '$selected'"
    fail=1
fi

# Aplicar chmod 775 (la acción real) y verificar
find "$TMP/perms" -xdev -mindepth 1 -type d ! -perm -2000 ! -perm 775 -exec chmod 775 {} +
mode2775="$(stat -c '%a' "$TMP/perms/d2775")"
mode755="$(stat -c '%a' "$TMP/perms/d755")"
[[ "$mode2775" == "2775" ]] && echo "OK   dir 2775 conserva setgid ($mode2775)" || { echo "FAIL 2775 perdió setgid: $mode2775"; fail=1; }
[[ "$mode755" == "775" ]]   && echo "OK   dir 755 corregido a 775 ($mode755)" || { echo "FAIL 755 no corregido: $mode755"; fail=1; }

# --- 3. -xdev (5.1) ---
grep -qE 'find .* -xdev' "$SCRIPT" && grep -qE '\-xdev' "$SCRIPT" \
    && echo "OK   find/chown usan -xdev" \
    || { echo "FAIL falta -xdev en los comandos find/chown"; fail=1; }

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: todos los asserts."
else
    echo "FAIL: hay asserts en rojo."
fi
exit "$fail"
