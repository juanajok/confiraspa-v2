#!/bin/bash
set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

log_section "Instalación de Dependencia: Mono Project"

# 1. Idempotencia: Verificar si ya existe
if command -v mono &> /dev/null; then
    # Opcional: Verificar versión
    MONO_VERSION=$(mono --version | head -n 1 | awk '{print $5}')
    log_success "Mono ya está instalado (v$MONO_VERSION). Saltando instalación."
    exit 0
fi

log_info "Mono no detectado. Iniciando instalación..."

# 2. Instalar prerrequisitos para HTTPS y GPG
execute_cmd "apt-get install -y dirmngr gnupg apt-transport-https ca-certificates" "Instalando herramientas de repo"

# 3. Configurar Clave GPG (Método Robust/Idempotente)
KEYRING="/usr/share/keyrings/mono-official-archive-keyring.gpg"
if [ ! -f "$KEYRING" ]; then
    log_info "Añadiendo clave GPG de Mono..."
    # Descargamos la key y la convertimos a formato gpg usable por apt
    curl -fsSL https://download.mono-project.com/repo/xamarin.gpg | \
        gpg --dearmor | \
        sudo tee "$KEYRING" > /dev/null
else
    log_info "Clave GPG ya presente."
fi

# 4. Configurar Repositorio (Detectando versión de Debian/Raspbian)
REPO_FILE="/etc/apt/sources.list.d/mono-official-stable.list"
DEBIAN_VERSION=$(lsb_release -cs) # bookworm, bullseye, buster...

if [ ! -f "$REPO_FILE" ]; then
    log_info "Añadiendo repositorio para Debian $DEBIAN_VERSION..."
    echo "deb [signed-by=$KEYRING] https://download.mono-project.com/repo/debian stable-$DEBIAN_VERSION main" | \
        sudo tee "$REPO_FILE" > /dev/null
fi

# 5. Actualizar e Instalar
# Nota: execute_cmd maneja el dry-run
execute_cmd "apt-get update -qq" "Actualizando lista de paquetes con nuevo repo"
execute_cmd "apt-get install -y mono-complete" "Instalando Mono Complete (esto puede tardar)"

# 6. Verificación final
if ! command -v mono &> /dev/null; then
    log_error "La instalación de Mono parece haber fallado."
    exit 1
fi

log_success "Mono instalado correctamente."

