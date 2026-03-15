#!/bin/bash
# scripts/30-services/amule.sh
# Descripción: Instalación de aMule Daemon con configuración declarativa y MD5
# Autor: Juan José Hipólito (Refactorizado v3 - Post Security Review)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# Hacemos readonly la raíz para consistencia
readonly REPO_ROOT

source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# --- CONSTANTES ---
readonly SERVICE="amule-daemon"
readonly AMULE_USER="amule"
readonly AMULE_HOME="/var/lib/amule"
readonly CONF_DIR="$AMULE_HOME/.aMule"
readonly TEMPLATE_FILE="$REPO_ROOT/configs/static/templates/amule.conf"
readonly TARGET_CONF="$CONF_DIR/amule.conf"

# Variables del .env (Fail Fast si faltan)
AMULE_PASS="${AMULE_PASS:-}"
AMULE_WEB_PASS="${AMULE_WEB_PASS:-}"

log_section "Configuración de Red P2P (aMule)"

# 1. Validaciones
validate_root
ensure_package "amule-daemon"
ensure_package "amule-utils"  # Herramientas CLI
ensure_package "gettext-base" # Para envsubst

if [ -z "$AMULE_PASS" ] || [ -z "$AMULE_WEB_PASS" ]; then
    log_error "SEGURIDAD: Faltan credenciales en .env (AMULE_PASS o AMULE_WEB_PASS)."
    exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
    log_error "Falta la plantilla de configuración: $TEMPLATE_FILE"
    exit 1
fi

# 2. Gestión de Usuario y Directorios
log_info "Configurando entorno de usuario..."

# Usuario de sistema sin login
if ! id "$AMULE_USER" &>/dev/null; then
    execute_cmd "useradd --system --home-dir $AMULE_HOME --shell /bin/false $AMULE_USER"
fi

# Estructura de directorios
for DIR in "$AMULE_HOME" "$AMULE_HOME/Incoming" "$AMULE_HOME/Temp" "$CONF_DIR"; do
    if [ ! -d "$DIR" ]; then
        mkdir -p "$DIR"
    fi
    # Permisos estrictos: Solo el usuario amule puede ver sus archivos (750)
    chown -R "$AMULE_USER:$AMULE_USER" "$DIR"
    chmod 750 "$DIR"
done

# 3. Preparación de Variables para la Plantilla
log_info "Calculando hashes y variables..."

# MD5 Robusto: printf evita el salto de línea oculto de 'echo' que rompe el hash
AMULE_PASS_MD5=$(printf "%s" "$AMULE_PASS" | md5sum | awk '{print $1}')
AMULE_WEB_PASS_MD5=$(printf "%s" "$AMULE_WEB_PASS" | md5sum | awk '{print $1}')

# Aseguramos HOSTNAME (algunos entornos sudo minimalistas no lo heredan)
HOSTNAME="$(hostname)"

# Exportamos SOLO lo necesario para envsubst
export AMULE_HOME HOSTNAME AMULE_PASS_MD5 AMULE_WEB_PASS_MD5

# 4. Generación de Configuración
log_info "Desplegando configuración..."

# Parada preventiva del servicio
if systemctl is-active --quiet "$SERVICE"; then
    execute_cmd "systemctl stop $SERVICE"
fi

# Backup Robusto
if [ -f "$TARGET_CONF" ]; then
    BACKUP_FILE="${TARGET_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$TARGET_CONF" "$BACKUP_FILE"
fi

# Generación controlada con Whitelist de variables
# Esto evita sustituciones accidentales si el archivo contiene otros símbolos '$'
envsubst '${AMULE_HOME} ${HOSTNAME} ${AMULE_PASS_MD5} ${AMULE_WEB_PASS_MD5}' \
    < "$TEMPLATE_FILE" | execute_cmd "tee $TARGET_CONF" > /dev/null

# Permisos CRÍTICOS (el archivo contiene hashes, mejor protegerlo)
chown "$AMULE_USER:$AMULE_USER" "$TARGET_CONF"
chmod 600 "$TARGET_CONF"

# 5. Configuración del Servicio (/etc/default)
DEFAULT_FILE="/etc/default/amule-daemon"
log_info "Configurando demonio en $DEFAULT_FILE..."
cat <<EOF | execute_cmd "tee $DEFAULT_FILE" > /dev/null
AMULED_USER="$AMULE_USER"
AMULED_HOME="$AMULED_HOME"
EOF

# 6. Inicio y Verificación
log_info "Iniciando aMule Daemon..."
execute_cmd "systemctl daemon-reload"
execute_cmd "systemctl enable --now $SERVICE"

# Espera activa simple (aMule es lento en arrancar)
log_info "Esperando arranque del servicio..."
sleep 5

if systemctl is-active --quiet "$SERVICE"; then
    # Obtener IP
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    
    log_success "aMule operativo."
    log_info "---------------------------------------------------"
    log_info "Web UI:     http://$CURRENT_IP:4711"
    log_info "Password:   (Definida en .env)"
    log_info "Directorios: $AMULE_HOME"
    log_info "---------------------------------------------------"
else
    log_error "El servicio no arrancó. Logs: 'journalctl -u $SERVICE'"
    exit 1
fi