#!/bin/bash
# bootstrap.sh — Versión Corregida 2.3.2
# IMPORTANTE: lib/utils.sh no está disponible aquí aún — usar echo, no log_info.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Debe ejecutarse como root (sudo ./bootstrap.sh)"
    exit 1
fi

echo "Instalando dependencias base..."
apt-get update -qq
apt-get install -y git jq curl gettext-base

# Hacer ejecutables los scripts SIEMPRE, antes de entrar en la lógica del .env
echo "Asegurando permisos de ejecución en scripts..."
find "${SCRIPT_DIR}" -name "*.sh" -exec chmod +x {} +

if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    echo "No se encontró .env. Creando desde plantilla..."
    cp "${SCRIPT_DIR}/.env.example" "${SCRIPT_DIR}/.env"
    echo "-------------------------------------------------------"
    echo "ACCION REQUERIDA: Edita el archivo .env ahora mismo."
    echo "Comando: nano ${SCRIPT_DIR}/.env"
    echo "-------------------------------------------------------"
    # Salimos aquí para que el usuario configure y luego lance install.sh
    exit 0
fi

echo "Entorno listo. Ejecuta: sudo ./install.sh"
