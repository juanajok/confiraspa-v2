#!/bin/bash
# scripts/30-services/calibre.sh
# Descripción: Instalación de Calibre Server (Oficial) integrado con Readarr/NAS
# Autor: Juan José Hipólito (Refactorizado v3 - Final Release)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# --- CONSTANTES ---
readonly SERVICE="calibre-server"
readonly INSTALL_DIR="/opt/calibre"
readonly CALIBRE_USER="calibre"
# Grupo multimedia (para leer/escribir en la carpeta de libros de Readarr)
readonly MEDIA_GROUP="${ARR_GROUP:-media}"
readonly PORT="8080"

# Ruta de la Biblioteca (Del .env o default)
# Debe coincidir con la "Root Folder" de Readarr para evitar duplicidad
readonly LIBRARY_PATH="${DIR_BOOKS:-/media/WDElements/Libros}"

log_section "Instalación de Servidor de eBooks (Calibre)"

# 1. Validaciones de Sistema
validate_root

# CHECK DE ARQUITECTURA (Fail Fast)
# Calibre moderno (>v6) exige 64 bits. En armhf (32bit) el instalador falla o instala versiones rotas.
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    log_error "Arquitectura no soportada: $ARCH"
    log_error "Calibre Server oficial requiere un sistema operativo de 64 bits (arm64/amd64)."
    log_error "Si estás en Raspberry Pi OS 32-bit, debes reinstalar el SO o usar una versión legacy."
    exit 1
fi

# Dependencias (Críticas para Bookworm/Bullseye)
ensure_package "wget"
ensure_package "python3"
ensure_package "xz-utils"
ensure_package "xdg-utils"
ensure_package "libxcb-cursor0" # Fix visual/headless
ensure_package "libegl1" 
ensure_package "libopengl0"

# 2. Gestión de Usuario
log_info "Configurando identidad del servicio..."

# Verificar si el usuario existe (de forma segura para Dry-Run)
if ! id "$CALIBRE_USER" &>/dev/null; then
    execute_cmd "Creando usuario $CALIBRE_USER" "useradd --system --shell /bin/false --home-dir /var/lib/calibre $CALIBRE_USER"
fi

# INTEGRACIÓN NAS: Solo intentar añadir al grupo si el usuario existe o no es Dry-Run
if [[ "${DRY_RUN:-false}" == "false" ]]; then
    if ! id -nG "$CALIBRE_USER" | grep -qw "$MEDIA_GROUP"; then
        execute_cmd "Integrando en grupo $MEDIA_GROUP" "usermod -aG $MEDIA_GROUP $CALIBRE_USER"
    fi
else
    log_warning "[DRY-RUN] Saltando integración de grupos (el usuario aún no existe físicamente)."
fi

# 3. Instalación de Binarios (Oficial)
if [ -x "$INSTALL_DIR/calibre-server" ]; then
    log_info "Calibre ya está instalado en $INSTALL_DIR."
else
    log_info "Descargando e instalando Calibre (Latest)..."
    
    # Instalación directa sin 'eval' (Más seguro y robusto)
    # isolated=y: No toca /usr/bin, todo queda en /opt/calibre
    # Verificación post-instalación
    if [[ "${DRY_RUN:-false}" == "false" ]]; then
        if [ ! -x "$INSTALL_DIR/calibre-server" ]; then
            log_error "La instalación parece haber fallado. No se encuentra el binario."
            exit 1
        fi
        log_success "Calibre instalado correctamente."
    else
        log_warning "[DRY-RUN] Validación de binario omitida (instalación no ejecutada)."
    fi
fi

# 4. Configuración de Biblioteca (Permisos NAS)
log_info "Configurando biblioteca en: $LIBRARY_PATH"

if [ ! -d "$LIBRARY_PATH" ]; then
    execute_cmd "mkdir -p $LIBRARY_PATH"
fi

# Permisos: Propietario Calibre, Grupo Media
execute_cmd "chown -R $CALIBRE_USER:$MEDIA_GROUP $LIBRARY_PATH"
# 775: Grupo puede escribir
execute_cmd "chmod -R 775 $LIBRARY_PATH"
# SetGID (g+s): Nuevos archivos heredarán grupo 'media' (Vital para Readarr)
execute_cmd "chmod g+s $LIBRARY_PATH"

# 5. Servicio Systemd
SERVICE_FILE="/etc/systemd/system/$SERVICE.service"
log_info "Configurando servicio Systemd..."

# --enable-local-write: Permite subir libros desde la LAN sin autenticación compleja
cat <<EOF | execute_cmd "tee $SERVICE_FILE" > /dev/null
[Unit]
Description=Calibre Content Server
After=network.target

[Service]
Type=simple
User=$CALIBRE_USER
Group=$MEDIA_GROUP
UMask=0002
ExecStart=$INSTALL_DIR/calibre-server --port $PORT --enable-local-write "$LIBRARY_PATH"
Restart=on-failure
RestartSec=10

# Security Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 6. Arranque
execute_cmd "systemctl daemon-reload"

if check_service_active "$SERVICE"; then
    log_info "Servicio ya activo. Reiniciando para aplicar cambios..."
    execute_cmd "systemctl restart $SERVICE"
else
    execute_cmd "systemctl enable --now $SERVICE"
fi

# 7. Verificación
if check_service_active "$SERVICE"; then
    IP=$(hostname -I | awk '{print $1}')
    log_success "Calibre Server operativo."
    log_info "---------------------------------------------------"
    log_info "Web UI:     http://$IP:$PORT"
    log_info "Biblioteca: $LIBRARY_PATH"
    log_info "Integración: Grupo '$MEDIA_GROUP' + SetGID activo."
    log_info "---------------------------------------------------"
else
    log_error "Calibre no arrancó. Revisa: 'journalctl -u $SERVICE'"
    exit 1
fi