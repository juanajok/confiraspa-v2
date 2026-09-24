#!/bin/bash
# scripts/30-services/bazarr.sh
# Descripción: Instalación nativa de Bazarr en entorno virtual (PEP 668 Compliant)
# Autor: Juan José Hipólito (Refactorizado v3 - Final Release)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"

# Cargar .env si no estamos bajo install.sh (ej: --only bazarr)
if [[ -f "$REPO_ROOT/.env" ]]; then
    source "$REPO_ROOT/.env"
fi
# --------------------------

# --- VARIABLES Y CONSTANTES ---
readonly SERVICE="bazarr"
readonly INSTALL_DIR="/opt/Bazarr"
readonly DATA_DIR="/var/lib/bazarr"
readonly VENV_DIR="$INSTALL_DIR/venv"
readonly TEMP_FILE="/tmp/bazarr.zip"

# FIX 18.1: versión y SHA256 fijados (NO usar 'latest': mutable y no verificable).
# El hash lo publica GitHub como 'digest' del asset bazarr.zip. Actualizar AMBOS
# al subir de versión: https://github.com/morpheus65535/bazarr/releases
readonly BAZARR_VERSION="v1.6.1"
readonly BAZARR_DOWNLOAD_URL="https://github.com/morpheus65535/bazarr/releases/download/${BAZARR_VERSION}/bazarr.zip"
readonly BAZARR_SHA256="9fb83af026da7e9b7aa52d7547dfd15e7efa872ee90c7a5ecbe4bc6f213670e9"

# Usuario del stack Arr
readonly USER_NAME="${ARR_USER:-media}"
readonly GROUP_NAME="${ARR_GROUP:-media}"

# --- TRAP DE LIMPIEZA ---
cleanup() {
    if [ -f "$TEMP_FILE" ]; then
        rm -f "$TEMP_FILE"
    fi
}
trap cleanup EXIT

log_section "Instalación de Gestor de Subtítulos (Bazarr)"

# 1. Validaciones y Dependencias
validate_root

# Dependencias de compilación y Python (Debian 12+)
ensure_package "curl"
ensure_package "unzip"
ensure_package "python3-venv" # Vital para aislar el entorno
ensure_package "python3-dev"
ensure_package "python3-pip"
ensure_package "libxml2-dev"
ensure_package "libxslt1-dev"
ensure_package "zlib1g-dev"
# Dependencia a veces olvidada para compilación de lxml
ensure_package "build-essential"

# 2. Verificación de Identidad
log_info "Verificando usuario de servicio ($USER_NAME)..."
if ! id "$USER_NAME" &>/dev/null; then
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "[DRY-RUN] Usuario '$USER_NAME' no existe en este entorno (normal en simulación)."
    else
        log_error "El usuario '$USER_NAME' no existe. Ejecuta 'scripts/00-system/10-users.sh' primero."
        exit 1
    fi
fi

# 3. Instalación de Código Fuente (Idempotente)
# Verificamos si existe el script principal
if [ -f "$INSTALL_DIR/bazarr.py" ]; then
    log_info "Bazarr ya está instalado en $INSTALL_DIR."
    log_info "Saltando descarga (Modo No-Upgrade)."
else
    log_info "Iniciando instalación limpia..."
    
    # FIX 18.1: versión fijada + SHA256 (fallo cerrado). Antes: 'latest' mutable
    # + curl sin verificar + pip install -r del zip = RCE en instalación.
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "[DRY-RUN] Descargaría y verificaría Bazarr ${BAZARR_VERSION} (SHA256)."
    else
        log_info "Descargando Bazarr ${BAZARR_VERSION} (verificando SHA256)..."
        if ! download_secure "${BAZARR_DOWNLOAD_URL}" "${TEMP_FILE}" "${BAZARR_SHA256}"; then
            log_error "Descarga o verificación SHA256 fallida. Abortando SIN ejecutar pip."
            exit 1
        fi
    fi
    
    # Limpieza de directorio previo
    if [ -d "$INSTALL_DIR" ]; then rm -rf "$INSTALL_DIR"; fi
    mkdir -p "$INSTALL_DIR"
    
    log_info "Extrayendo..."
    execute_cmd "unzip -q -o $TEMP_FILE -d $INSTALL_DIR" "Extrayendo archivos de Bazarr"

    # --- CORRECCIÓN AQUÍ ---
    # Solo validamos la existencia si NO estamos en modo Dry-Run
    if [[ "${DRY_RUN:-false}" == "false" ]]; then
        if [ ! -f "$INSTALL_DIR/bazarr.py" ]; then
            log_error "Error crítico: bazarr.py no encontrado tras la extracción."
            log_error "Es posible que la estructura del zip oficial haya cambiado."
            exit 1
        fi
        log_success "Validación de binarios completada."
    else
        log_warning "[DRY-RUN] Saltando validación de archivos (el archivo aún no existe)."
    fi
fi

# 4. Configuración del Entorno Virtual (VENV)
# Esto es obligatorio en Debian 12 Bookworm para no romper el sistema (PEP 668)
log_info "Configurando entorno Python aislado (venv)..."

if [ ! -d "$VENV_DIR" ]; then
    execute_cmd "python3 -m venv $VENV_DIR" "Creando virtualenv"
fi

# Definimos rutas a los ejecutables DENTRO del venv
PIP_CMD="$VENV_DIR/bin/pip"
PYTHON_CMD="$VENV_DIR/bin/python"

log_info "Instalando dependencias Python (requirements.txt)..."
# Actualizar pip interno
execute_cmd "$PIP_CMD install --upgrade pip --quiet"
# Instalar requerimientos.
# SECURITY: requirements.txt proviene del ZIP verificado por SHA256 (trusted).
# Riesgo residual: los paquetes se bajan de PyPI sin pinning por hash — mitigarlo
# requeriría mantener un requirements.txt propio con --require-hashes.
execute_cmd "$PIP_CMD install -r $INSTALL_DIR/requirements.txt --quiet"

# 5. Permisos y Datos
log_info "Ajustando permisos..."
if [ ! -d "$DATA_DIR" ]; then mkdir -p "$DATA_DIR"; fi

# Asignamos propiedad recursiva
execute_cmd "chown -R $USER_NAME:$GROUP_NAME $INSTALL_DIR"
execute_cmd "chown -R $USER_NAME:$GROUP_NAME $DATA_DIR"
# Permisos NAS-friendly
execute_cmd "chmod 775 $DATA_DIR"

# 6. Servicio Systemd
SERVICE_FILE="/etc/systemd/system/bazarr.service"
log_info "Configurando servicio Systemd..."

cat <<EOF | execute_cmd "tee $SERVICE_FILE" > /dev/null
[Unit]
Description=Bazarr Daemon (Native Python Venv)
After=network.target

[Service]
User=$USER_NAME
Group=$GROUP_NAME
UMask=0002
Type=simple
# CRÍTICO: Usamos el Python del VENV, no el del sistema
# --no-update: Delegamos las actualizaciones a este script, no al auto-update interno
ExecStart=$PYTHON_CMD $INSTALL_DIR/bazarr.py --no-update --config $DATA_DIR
TimeoutStopSec=20
KillMode=process
Restart=on-failure

# Security Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 7. Arranque
execute_cmd "systemctl daemon-reload"

if check_service_active "$SERVICE"; then
    log_info "Servicio ya activo."
else
    execute_cmd "systemctl enable --now $SERVICE" "Iniciando servicio"
fi

# 8. Verificación Final
if check_service_active "$SERVICE"; then
    IP=$(hostname -I | awk '{print $1}')
    log_success "Bazarr instalado correctamente."
    log_info "---------------------------------------------------"
    log_info "URL:        http://$IP:6767"
    log_info "Entorno:    $VENV_DIR"
    log_info "Config:     $DATA_DIR"
    log_info "---------------------------------------------------"
else
    log_error "Bazarr no arrancó. Revisa: 'journalctl -u $SERVICE -n 50'"
    exit 1
fi