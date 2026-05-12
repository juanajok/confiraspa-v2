#!/bin/bash
# scripts/30-services/transmission.sh
# Descripción: Instalación de Transmission Daemon con configuración NAS y permisos 'media'
# Autor: Juan José Hipólito (Refactorizado v3 - Post Security Review)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# Hacemos readonly la raíz para garantizar consistencia
readonly REPO_ROOT

source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"

# Cargar .env si no estamos bajo install.sh (ej: --only transmission)
if [[ -f "$REPO_ROOT/.env" ]]; then
    source "$REPO_ROOT/.env"
fi
# --------------------------

# --- VARIABLES Y CONSTANTES ---
readonly TEMPLATE_FILE="$REPO_ROOT/configs/static/templates/transmission.json"
readonly TARGET_CONF="/etc/transmission-daemon/settings.json"
readonly SERVICE="transmission-daemon"
readonly TM_USER="debian-transmission"
# Grupo multimedia definido en .env o default
readonly MEDIA_GROUP="${ARR_GROUP:-media}"

log_section "Configuración de Gestor de Descargas (Transmission)"

# 1. Validaciones de Sistema y Seguridad
validate_root
ensure_package "transmission-daemon"
ensure_package "jq"           # Para validar JSON
ensure_package "gettext-base" # Para envsubst

if [ ! -f "$TEMPLATE_FILE" ]; then
    log_error "Falta la plantilla de configuración: $TEMPLATE_FILE"
    exit 1
fi

# SECURITY CHECK: Fail Fast si no hay contraseña
if [ -z "${TRANSMISSION_PASS:-}" ]; then
    log_error "SEGURIDAD: La variable TRANSMISSION_PASS no está definida en .env"
    log_error "Por favor, define una contraseña segura antes de continuar."
    exit 1
fi

# 2. Preparación de Variables de Entorno
# Defaults seguros para variables no críticas
TRANSMISSION_USER="${TRANSMISSION_USER:-admin}"
TRANSMISSION_PEER_PORT="${TRANSMISSION_PEER_PORT:-51413}"

# DIR_TORRENTS y DIR_TORRENTS_TEMP vienen de .env (via PATH_DOWNLOADS).
# Los fallbacks apuntan a la ruta correcta actual — solo como red de seguridad.
export DIR_TORRENTS="${DIR_TORRENTS:-/media/Descargas/torrents/completos}"
export DIR_INCOMPLETE="${DIR_TORRENTS_TEMP:-/media/Descargas/torrents/temp}"

# Exportamos explícitamente las variables que usará la plantilla
export TRANSMISSION_USER TRANSMISSION_PASS TRANSMISSION_PEER_PORT

# 3. Parada del Servicio (CRÍTICO)
# Transmission sobrescribe settings.json al cerrarse. 
# Debemos pararlo ANTES de tocar nada.
if check_service_active "$SERVICE"; then
    log_info "Deteniendo servicio Transmission para aplicar configuración..."
    execute_cmd "systemctl stop $SERVICE"
fi

# 4. Gestión de Permisos y Grupos (Fix para Sonarr/Radarr)
log_info "Integrando usuario '$TM_USER' en grupo '$MEDIA_GROUP'..."

# Idempotencia: Solo añadir si no pertenece ya
if ! id -nG "$TM_USER" | grep -qw "$MEDIA_GROUP"; then
    execute_cmd "usermod -aG $MEDIA_GROUP $TM_USER" "Añadiendo usuario al grupo"
fi

# 5. Configuración de Directorios (SetGID Magic)
log_info "Preparando directorios de descarga..."
for DIR in "$DIR_TORRENTS" "$DIR_INCOMPLETE"; do
    if [ ! -d "$DIR" ]; then
        execute_cmd "mkdir -p $DIR"
    fi
    
    # Propietario: Transmission. Grupo: Media.
    execute_cmd "chown -R $TM_USER:$MEDIA_GROUP $DIR"
    
    # Permisos 775: Grupo puede escribir.
    execute_cmd "chmod -R 775 $DIR"
    
    # SetGID (2775): Hace que los archivos nuevos hereden el grupo 'media'
    # Esto asegura que Sonarr siempre pueda moverlos.
    execute_cmd "chmod g+s $DIR" 
done

# 6. Generación de Configuración
# Backup con timestamp de alta resolución
if [ -f "$TARGET_CONF" ]; then
    BACKUP_FILE="${TARGET_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$TARGET_CONF" "$BACKUP_FILE"
fi

log_info "Generando settings.json desde plantilla..."

# Usamos envsubst CON WHITELIST de variables para evitar corromper otros $ del JSON
envsubst '${DIR_TORRENTS} ${DIR_INCOMPLETE} ${TRANSMISSION_USER} ${TRANSMISSION_PASS} ${TRANSMISSION_PEER_PORT}' \
    < "$TEMPLATE_FILE" | execute_cmd "tee $TARGET_CONF" > /dev/null

# Validación de integridad JSON (Safety Net)
if ! run_check "jq . $TARGET_CONF" "Validando integridad del JSON de Transmission"; then
    log_error "El JSON generado es inválido. Restaurando backup..."
    if [[ -n "${BACKUP_FILE:-}" && -f "$BACKUP_FILE" ]]; then cp "$BACKUP_FILE" "$TARGET_CONF"; fi
    exit 1
fi

# 7. Inicio del Servicio
log_info "Iniciando Transmission..."
execute_cmd "systemctl start $SERVICE"
execute_cmd "systemctl enable $SERVICE"

# 8. Verificación Final y UX
if check_service_active "$SERVICE"; then
    # Obtener IP real
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    
    log_success "Transmission operativo."
    log_info "---------------------------------------------------"
    log_info "URL:        http://$CURRENT_IP:$TRANSMISSION_PEER_PORT"
    log_info "Usuario:    $TRANSMISSION_USER"
    log_info "Contraseña: (Definida en .env)"
    log_info "Descargas:  $DIR_TORRENTS"
    log_info "---------------------------------------------------"
else
    log_error "El servicio no arrancó. Revisa: journalctl -u $SERVICE"
    exit 1
fi