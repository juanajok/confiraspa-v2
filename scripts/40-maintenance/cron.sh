#!/bin/bash
# scripts/40-maintenance/cron.sh
# Descripción: Gestión de Cron con rutas dinámicas (C8 Fix)
# Autor: Juan José Hipólito

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

readonly SOURCE_FILE="$REPO_ROOT/configs/static/crontabs.txt"
readonly BACKUP_FILE=$(mktemp /tmp/confiraspa_cron_backup.XXXXXX)
readonly NEW_CRON_FILE=$(mktemp /tmp/confiraspa_cron_new.XXXXXX)

cleanup() { rm -f "$BACKUP_FILE" "$NEW_CRON_FILE"; }
trap cleanup EXIT

log_section "Configuración de Cron (v2.2 - Dynamic Paths)"

validate_root
ensure_package "gettext-base" # Necesario para envsubst

# 1. Backup
crontab -l > "$BACKUP_FILE" 2>/dev/null || touch "$BACKUP_FILE"

# 2. C8 FIX: Personalización dinámica de rutas
log_info "Inyectando ruta del repositorio: $REPO_ROOT"
# Exportamos la variable para que envsubst la vea
export CONFIRASPA_ROOT="$REPO_ROOT"

{
    echo "# --- CRONTAB GESTIONADO POR CONFIRASPA ($(date)) ---"
    # envsubst lee crontabs.txt y cambia ${CONFIRASPA_ROOT} por la ruta real
    envsubst '${CONFIRASPA_ROOT}' < "$SOURCE_FILE"
    echo "" 
} > "$NEW_CRON_FILE"

chmod 600 "$NEW_CRON_FILE"

# 3. Instalación
if crontab "$NEW_CRON_FILE"; then
    log_success "Tareas programadas instaladas con rutas dinámicas."
else
    log_error "Error al instalar crontab."
    [ -s "$BACKUP_FILE" ] && crontab "$BACKUP_FILE"
    exit 1
fi