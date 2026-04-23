#!/bin/bash
# bootstrap.sh — Versión Corregida 2.3.1
set -euo pipefail

# C1: Espacio corregido entre if y [
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Debe ejecutarse como root (sudo ./bootstrap.sh)"
    exit 1
fi

echo "📦 Instalando dependencias base..."
apt-get update -qq
apt-get install -y git jq curl

# C4: Hacer ejecutables los scripts SIEMPRE, antes de entrar en la lógica del .env
log_info "Asegurando permisos de ejecución en scripts..."
find . -name "*.sh" -exec chmod +x {} +

if [ ! -f .env ]; then
    log_warning "No se encontró .env. Creando desde plantilla..."
    cp .env.example .env
    echo "-------------------------------------------------------"
    echo "⚠️ ACCIÓN REQUERIDA: Edita el archivo .env ahora mismo."
    echo "Comando: nano .env"
    echo "-------------------------------------------------------"
    # Salimos aquí para que el usuario configure y luego lance install.sh
    exit 0
fi

echo "✅ Entorno listo. Ejecuta: sudo ./install.sh"