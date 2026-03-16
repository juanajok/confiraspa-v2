#!/bin/bash
# scripts/30-services/samba.sh
# Descripción: Configuración de Samba en modo NAS
# Autor: Juan José Hipólito (Refactorizado v3 - NAS Mode)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# --- VARIABLES ---
readonly TEMPLATE_FILE="$REPO_ROOT/configs/static/templates/smb.conf"
readonly TARGET_CONF="/etc/samba/smb.conf"

# Defaults
SMB_USER="${SMB_USER:-pi}"
SMB_PASS="${SMB_PASS:-}"
SMB_WORKGROUP="${SMB_WORKGROUP:-WORKGROUP}"

# EXPORTACIÓN DE VARIABLES PARA ENVSUBST (NAS MODE)
# Aquí es donde ocurre la magia. Exportamos las rutas raíz.
export PATH_LIBRARY="${PATH_LIBRARY:-/media/WDElements}"
export PATH_BACKUP="${PATH_BACKUP:-/media/Backup}"
# Mapeamos tu petición de "completo" a la variable DIR_TORRENTS
export DIR_TORRENTS="${DIR_TORRENTS:-/media/DiscoDuro/completo}"

export SMB_USER SMB_WORKGROUP

log_section "Configuración de Servidor NAS (Samba)"

# 1. Validaciones
validate_root
ensure_package "samba"
ensure_package "samba-common-bin" 
ensure_package "gettext-base"

if [ -z "$SMB_PASS" ]; then
    log_error "La variable SMB_PASS está vacía en el .env."
    exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
    log_error "Falta la plantilla: $TEMPLATE_FILE"
    exit 1
fi

# 2. Backup
BACKUP_FILE=""
if [ -f "$TARGET_CONF" ]; then
    BACKUP_FILE="${TARGET_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    log_info "Backup config anterior: $BACKUP_FILE"
    cp "$TARGET_CONF" "$BACKUP_FILE"
fi

# 3. Generación de Configuración
log_info "Generando configuración NAS..."

# Aseguramos que la carpeta "completo" exista antes de compartirla
# CORRECCIÓN: Envolvemos los comandos en execute_cmd para respetar el modo dry-run
if [ ! -d "$DIR_TORRENTS" ]; then
    execute_cmd "mkdir -p $DIR_TORRENTS" "Creando directorio de descargas"
    execute_cmd "chown $SMB_USER:media $DIR_TORRENTS" "Asignando propietario"
    execute_cmd "chmod 775 $DIR_TORRENTS" "Ajustando permisos"
fi

# Inyectamos las variables de RUTAS PADRE
envsubst '${SMB_WORKGROUP} ${SMB_USER} ${PATH_LIBRARY} ${PATH_BACKUP} ${DIR_TORRENTS}' < "$TEMPLATE_FILE" | \
    execute_cmd "tee $TARGET_CONF" > /dev/null

# 4. Verificación y Restauración
if ! run_check "testparm -s $TARGET_CONF" "Verificando smb.conf"; then
    log_error "Configuración de Samba inválida."
    if [[ -n "${BACKUP_FILE-}" && -f "$BACKUP_FILE" ]]; then
        cp "$BACKUP_FILE" "$TARGET_CONF"
        log_warning "Backup de Samba restaurado."
    fi
    exit 1
fi

# 5. Usuarios y Servicios
log_info "Actualizando usuario Samba: $SMB_USER"
if ! id "$SMB_USER" &>/dev/null; then
    if [[ "${DRY_RUN:-false}" = true ]]; then
        log_warning "[DRY-RUN] Usuario '$SMB_USER' no existe en este entorno (normal en simulación)."
    else
        log_error "Usuario sistema '$SMB_USER' no existe. Ejecuta 10-users.sh primero."
        exit 1
    fi
fi

(echo "$SMB_PASS"; echo "$SMB_PASS") | execute_cmd "smbpasswd -s -a $SMB_USER" "Set Password"
execute_cmd "smbpasswd -e $SMB_USER" "Enable User"

log_info "Reiniciando Samba..."
execute_cmd "systemctl restart smbd nmbd"

# 6. Info
if check_service_active smbd; then
    IP=$(hostname -I | awk '{print $1}')
    log_success "NAS Operativo."
    log_info "Recursos compartidos:"
    log_info "  - \\\\$IP\\WDElements"
    log_info "  - \\\\$IP\\Backup"
    log_info "  - \\\\$IP\\Descargas"
else
    log_error "Fallo al iniciar Samba."
    exit 1
fi