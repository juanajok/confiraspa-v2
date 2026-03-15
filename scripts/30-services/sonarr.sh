#!/bin/bash
# scripts/30-services/sonarr.sh
# Descripción: Instalación de Sonarr (v4 Nativo) con Hardening y Gestión NAS
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

# --- VARIABLES Y CONSTANTES ---
readonly SERVICE="sonarr"
readonly INSTALL_DIR="/opt/Sonarr"
readonly BINARY="$INSTALL_DIR/Sonarr"
readonly DATA_DIR="/var/lib/sonarr"
readonly TEMP_FILE="/tmp/sonarr.tar.gz"

# Usuario/Grupo del stack Arr (Definido en .env -> 10-users.sh)
readonly USER_NAME="${ARR_USER:-media}"
readonly GROUP_NAME="${ARR_GROUP:-media}"

# --- TRAP DE LIMPIEZA ---
# Asegura que no queden residuos en /tmp si el script falla o termina
cleanup() {
    if [ -f "$TEMP_FILE" ]; then
        rm -f "$TEMP_FILE"
    fi
}
trap cleanup EXIT

log_section "Instalación de Sonarr (Nativo .NET)"

# 1. Validaciones
validate_root
# Dependencias nativas de .NET en Linux
ensure_package "curl"
ensure_package "sqlite3"
ensure_package "libicu-dev"
ensure_package "libssl-dev"

# 2. Verificación de Usuario
log_info "Verificando identidad del servicio ($USER_NAME)..."
if ! id "$USER_NAME" &>/dev/null; then
    log_error "El usuario '$USER_NAME' no existe. Ejecuta 'scripts/00-system/10-users.sh' primero."
    exit 1
fi

# 3. Lógica de Instalación Inteligente
if [ -x "$BINARY" ]; then
    log_info "Sonarr ya está instalado en $INSTALL_DIR."
    log_info "Saltando descarga. Se verificarán permisos y servicio."
else
    log_info "Binario no encontrado. Iniciando instalación limpia..."
    
    # A. Detectar Arquitectura
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64) SONARR_ARCH="x64" ;;
        arm64) SONARR_ARCH="arm64" ;; # Raspberry Pi 4/5 (64bit)
        armhf) SONARR_ARCH="arm" ;;   # Raspberry Pi 3/Zero 2 (32bit)
        *) log_error "Arquitectura no soportada: $ARCH"; exit 1 ;;
    esac
    
    # B. Descarga
    DL_URL="https://services.sonarr.tv/v1/download/main/latest?version=4&os=linux&arch=$SONARR_ARCH"
    log_info "Descargando Sonarr v4 ($SONARR_ARCH)..."
    execute_cmd "curl -sL -o $TEMP_FILE '$DL_URL'" "Descarga completada"
    
    # C. Limpieza previa (Upgrade seguro)
    if [ -d "$INSTALL_DIR" ]; then
        log_warning "Limpiando directorio de instalación previo..."
        rm -rf "$INSTALL_DIR"
    fi
    mkdir -p "$INSTALL_DIR"
    
    # D. Extracción
    log_info "Extrayendo binarios..."
    # --strip-components=1 elimina la carpeta contenedora 'Sonarr/' del tar
    execute_cmd "tar -xzf $TEMP_FILE -C $INSTALL_DIR --strip-components=1"
    
    # E. Permisos de Binarios
    execute_cmd "chown -R $USER_NAME:$GROUP_NAME $INSTALL_DIR"
fi

# 4. Configuración de Datos (Anti-Drift)
# Siempre aseguramos que los permisos sean correctos, incluso si ya estaba instalado
log_info "Asegurando permisos en directorio de datos..."
if [ ! -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR"
fi
execute_cmd "chown -R $USER_NAME:$GROUP_NAME $DATA_DIR"
# 775 para que el grupo (tu usuario samba) pueda ver logs/backups si es necesario
execute_cmd "chmod 775 $DATA_DIR"

# 5. Configuración del Servicio (Hardening)
SERVICE_FILE="/etc/systemd/system/sonarr.service"
log_info "Configurando unidad Systemd..."

cat <<EOF | execute_cmd "tee $SERVICE_FILE" > /dev/null
[Unit]
Description=Sonarr Daemon (v4 Native)
After=network.target

[Service]
User=$USER_NAME
Group=$GROUP_NAME
UMask=0002
Type=simple
ExecStart=$BINARY -nobrowser -data=$DATA_DIR
TimeoutStopSec=20
KillMode=process
Restart=on-failure

# Hardening / Seguridad
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

# 6. Inicio y Habilitación
log_info "Gestionando servicio..."
execute_cmd "systemctl daemon-reload"

if systemctl is-active --quiet "$SERVICE"; then
    log_info "Reiniciando servicio para aplicar cambios..."
    execute_cmd "systemctl restart $SERVICE"
else
    execute_cmd "systemctl enable --now $SERVICE"
fi

# 6. Inicio y Habilitación
log_info "Gestionando servicio..."
execute_cmd "systemctl daemon-reload"

if systemctl is-active --quiet "$SERVICE"; then
    log_info "Reiniciando servicio para aplicar cambios..."
    execute_cmd "systemctl restart $SERVICE"
else
    execute_cmd "systemctl enable --now $SERVICE"
fi

# 7. Verificación Final con Health Check
# Primero miramos si el proceso existe
if systemctl is-active --quiet "$SERVICE"; then
    
    # AHORA miramos si el puerto responde (Health Check Real)
    # Esperamos hasta 30 segundos a que arranque .NET
    if wait_for_service "localhost" "8989" "Sonarr"; then
        IP=$(hostname -I | awk '{print $1}')
        log_success "Sonarr instalado y respondiendo correctamente."
        log_info "---------------------------------------------------"
        log_info "URL:        http://$IP:8989"
        log_info "Binarios:   $INSTALL_DIR"
        log_info "Datos:      $DATA_DIR"
        log_info "---------------------------------------------------"
    else
        log_error "El servicio está activo pero NO responde en el puerto 8989."
        log_error "Puede ser un error de arranque de .NET. Revisa los logs."
        exit 1
    fi
else
    log_error "El servicio falló al iniciar. Revisa: 'journalctl -u $SERVICE -n 50'"
    exit 1
fi