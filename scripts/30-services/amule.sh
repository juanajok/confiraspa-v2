#!/bin/bash
# scripts/30-services/amule.sh
# Descripción: Instalación de aMule Daemon con configuración declarativa y MD5
# Autor: Juan José Hipólito (Refactorizado v4 - Dry-Run Proof)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"

# --- CONSTANTES ---
readonly SERVICE="amule-daemon"
readonly AMULE_USER="amule"
readonly AMULE_HOME="/var/lib/amule"
readonly CONF_DIR="$AMULE_HOME/.aMule"
readonly TEMPLATE_FILE="$REPO_ROOT/configs/static/templates/amule.conf"
readonly TARGET_CONF="$CONF_DIR/amule.conf"

AMULE_PASS="${AMULE_PASS:-}"
AMULE_WEB_PASS="${AMULE_WEB_PASS:-}"

log_section "Configuración de Red P2P (aMule)"

# 1. Validaciones
validate_root
ensure_package "amule-daemon"
ensure_package "amule-utils"
ensure_package "gettext-base"

if [ -z "$AMULE_PASS" ] || [ -z "$AMULE_WEB_PASS" ]; then
    log_error "SEGURIDAD: Faltan credenciales en .env."
    exit 1
fi

# 2. Gestión de Usuario y Directorios
log_info "Configurando entorno de usuario..."
if ! id "$AMULE_USER" &>/dev/null; then
    execute_cmd "Creando usuario de sistema $AMULE_USER" \
        "useradd --system --home-dir $AMULE_HOME --shell /bin/false $AMULE_USER"
fi

for DIR in "$AMULE_HOME" "$AMULE_HOME/Incoming" "$AMULE_HOME/Temp" "$CONF_DIR"; do
    if [ ! -d "$DIR" ]; then
        execute_cmd "Creando directorio: $DIR" "mkdir -p $DIR"
    fi
    execute_cmd "Asignando propietario $AMULE_USER a $DIR" "chown $AMULE_USER:$AMULE_USER $DIR"
    execute_cmd "Ajustando permisos (750) en $DIR" "chmod 750 $DIR"
done

# 3. Preparación de Variables
log_info "Calculando hashes y variables..."
AMULE_PASS_MD5=$(printf "%s" "$AMULE_PASS" | md5sum | awk '{print $1}')
AMULE_WEB_PASS_MD5=$(printf "%s" "$AMULE_WEB_PASS" | md5sum | awk '{print $1}')
HOSTNAME="$(hostname)"
export AMULE_HOME HOSTNAME AMULE_PASS_MD5 AMULE_WEB_PASS_MD5

# 4. Generación de Configuración
log_info "Desplegando configuración..."

if check_service_active "$SERVICE"; then
    execute_cmd "Deteniendo $SERVICE para configurar" "systemctl stop $SERVICE"
fi

if [ -f "$TARGET_CONF" ]; then
    # El backup también debe ser envuelto por consistencia en logs
    execute_cmd "Backup de configuración existente" "cp $TARGET_CONF ${TARGET_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
fi

# Generación del archivo
envsubst '${AMULE_HOME} ${HOSTNAME} ${AMULE_PASS_MD5} ${AMULE_WEB_PASS_MD5}' \
    < "$TEMPLATE_FILE" | execute_cmd "Escribiendo configuración amule.conf" "tee $TARGET_CONF" > /dev/null

# --- FIJADO: Estos comandos ahora son seguros para Dry-Run ---
execute_cmd "Protegiendo archivo de configuración" "chown $AMULE_USER:$AMULE_USER $TARGET_CONF"
execute_cmd "Ajustando permisos de archivo (600)" "chmod 600 $TARGET_CONF"

# 5. Configuración del Servicio
DEFAULT_FILE="/etc/default/amule-daemon"
log_info "Configurando demonio en $DEFAULT_FILE..."
cat <<EOF | execute_cmd "Generando archivo default" "tee $DEFAULT_FILE" > /dev/null
AMULED_USER="$AMULE_USER"
AMULED_HOME="$AMULE_HOME"
EOF

# 6. Inicio y Verificación
execute_cmd "Recargando systemd" "systemctl daemon-reload"
execute_cmd "Habilitando e iniciando $SERVICE" "systemctl enable --now $SERVICE"

sleep 2 # Un respiro para el daemon

if check_service_active "$SERVICE"; then
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    log_success "aMule operativo."
else
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_success "[DRY-RUN] Simulación de inicio completada."
    else
        log_error "El servicio no arrancó. Revisa: 'journalctl -u $SERVICE'"
        exit 1
    fi
fi