#!/bin/bash
set -euo pipefail

# CORRECCIÓN: Espacio añadido después del if
if [ "$(id -u)" -ne 0 ]; then
    echo "Por favor, ejecuta como root: sudo ./bootstrap.sh"
    exit 1
fi

echo "📦 Instalando dependencias mínimas..."   
apt-get update -qq
apt-get install -y git jq curl

if[ ! -f .env ]; then
    echo "⚠️ No se encontró .env. Creando desde ejemplo..." 
    cp .env.example .env
    echo "EDITA el archivo .env (nano .env) antes de continuar."
else
    chmod +x install.sh scripts/*/*.sh
    echo "✅ Entorno listo. Ejecuta: sudo ./install.sh" 
fi