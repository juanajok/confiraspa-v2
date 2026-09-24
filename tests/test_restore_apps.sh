#!/usr/bin/env bash
# tests/test_restore_apps.sh — verifica las protecciones de restauración (issue #8).
#
# Test de humo de los PRIMITIVOS de detección usados por restore_apps.sh:
#   1. 4.2 — un symlink plantado en un ZIP debe ser detectado con `[[ -L || ! -f ]]`
#            (verificado contra el comportamiento real de `unzip -j`, que SÍ
#            recrea la entrada symlink).
#   2. 5.2 — rutas con `..` o absolutas deben rechazarse.
#
# NOTA: no se ejecuta restore_from_zip end-to-end porque CONFIG_FILE es readonly
# en el script; aquí se valida el primitivo de detección exacto que usa el guard.
#
# Uso: bash tests/test_restore_apps.sh

set -euo pipefail

command -v zip >/dev/null 2>&1 || { echo "SKIP: 'zip' no disponible"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail=0

# --- 4.2: symlink plantado en ZIP ---
ln -s /etc/passwd "$TMP/config.xml"
(cd "$TMP" && zip -qy evil.zip config.xml) >/dev/null 2>&1

# Pre-scan (defensa en profundidad): unzip -Zl marca el symlink con modo 'l'
if unzip -Zl "$TMP/evil.zip" 2>/dev/null | grep -qE '^l'; then
    echo "OK   pre-scan detecta symlink (unzip -Zl, modo 'l')"
else
    echo "FAIL pre-scan no detecta symlink"
    fail=1
fi

mkdir -p "$TMP/out"
unzip -j -o "$TMP/evil.zip" "config.xml" -d "$TMP/out" >/dev/null 2>&1
extracted="$TMP/out/config.xml"

# Mismo guard que usa restore_from_zip
if [[ -L "$extracted" || ! -f "$extracted" ]]; then
    echo "OK   symlink en ZIP detectado y rechazado"
else
    echo "FAIL symlink en ZIP no detectado"
    fail=1
fi

# --- 5.2: traversal ---
rechazar() { [[ "$1" == *".."* || "$1" == /* ]]; }

if rechazar "../etc/passwd"; then echo "OK   '..' rechazado"; else echo "FAIL '..' no rechazado"; fail=1; fi
if rechazar "/etc/passwd";   then echo "OK   ruta absoluta rechazada"; else echo "FAIL ruta absoluta no rechazada"; fail=1; fi
if ! rechazar "config.xml";  then echo "OK   nombre limpio aceptado"; else echo "FAIL nombre limpio rechazado"; fail=1; fi

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: todos los asserts."
else
    echo "FAIL: hay asserts en rojo."
fi
exit "$fail"
