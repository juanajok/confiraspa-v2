#!/bin/bash
# scripts/30-services/rsync.sh
# Descripción: Instalación de Rsync Daemon (NAS Backup Server)
# Autor: Juan José Hipólito (Refactorizado v3 - Final Release)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"

# Cargar .env si no estamos bajo install.sh (ej: --only rsync)
if [[ -f "$REPO_ROOT/.env" ]]; then
    source "$REPO_ROOT/.env"
fi
# --------------------------

# --- VARIABLES ---
readonly SERVICE="rsync"
readonly TEMPLATE_FILE="$REPO_ROOT/configs/static/templates/rsyncd.conf"
readonly TARGET_CONF="/etc/rsyncd.conf"
readonly ENABLE_DAEMON_FILE="/etc/default/rsync"

# Identidad del servicio (Del .env)
readonly ARR_USER="${ARR_USER:-media}"
readonly ARR_GROUP="${ARR_GROUP:-media}"
export ARR_USER ARR_GROUP

# Rutas NAS
export PATH_BACKUP="${PATH_BACKUP:-/media/Backup}"
export DIR_TORRENTS="${DIR_TORRENTS:-/media/DiscoDuro/completos}"

log_section "Configuración de Sincronización (Rsync Server)"

# 1. Validaciones
validate_root
ensure_package "rsync"
ensure_package "gettext-base"

if [ ! -f "$TEMPLATE_FILE" ]; then
    log_error "Falta la plantilla: $TEMPLATE_FILE"
    exit 1
fi

# 2. Habilitación del Daemon (Debian Specific)
# Corrige el bloqueo por defecto en /etc/default/rsync
if [ -f "$ENABLE_DAEMON_FILE" ]; then
    log_info "Habilitando arranque en $ENABLE_DAEMON_FILE..."
    execute_cmd "sed -i 's/^RSYNC_ENABLE=false/RSYNC_ENABLE=true/' $ENABLE_DAEMON_FILE"
    execute_cmd "sed -i 's/^#RSYNC_ENABLE=true/RSYNC_ENABLE=true/' $ENABLE_DAEMON_FILE"
fi

# 3. Despliegue de Configuración
log_info "Desplegando configuración..."

# Backup rotativo
if [ -f "$TARGET_CONF" ]; then
    cp "$TARGET_CONF" "${TARGET_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
fi

# Inyección de variables
envsubst '${ARR_USER} ${ARR_GROUP} ${PATH_BACKUP} ${DIR_TORRENTS}' \
    < "$TEMPLATE_FILE" | execute_cmd "tee $TARGET_CONF" > /dev/null

execute_cmd "chmod 644 $TARGET_CONF"

# 4. Preparación de Directorios
# Aseguramos que el destino exista y tenga permisos correctos
if [ ! -d "$PATH_BACKUP" ]; then
    log_warning "El directorio NAS ($PATH_BACKUP) no existe. Creándolo..."
    # CORRECCIÓN: Envolvemos los comandos para que no se ejecuten en Dry-Run
    execute_cmd "mkdir -p $PATH_BACKUP" "Creando ruta de backup"
    execute_cmd "chown $ARR_USER:$ARR_GROUP $PATH_BACKUP" "Asignando propietario"
    execute_cmd "chmod 775 $PATH_BACKUP" "Ajustando permisos"
fi

# 5. Gestión del Servicio
log_info "Reiniciando servicio..."
execute_cmd "systemctl daemon-reload"

if check_service_active "$SERVICE"; then
    execute_cmd "systemctl restart $SERVICE"
else
    execute_cmd "systemctl enable --now $SERVICE"
fi

# 6. Verificación Final
if check_service_active "$SERVICE"; then
    IP=$(hostname -I | awk '{print $1}')
    log_success "Servidor Rsync operativo."
    log_info "---------------------------------------------------"
    log_info "Endpoint:   rsync://$IP/"
    log_info "Módulos:    [Backup] (RW), [Descargas] (RO)"
    log_info "Permisos:   Usuario '$ARR_USER', Grupo '$ARR_GROUP'"
    log_info "---------------------------------------------------"
else
    log_error "El servicio falló. Revisa: 'journalctl -u rsync'"
    exit 1
fi