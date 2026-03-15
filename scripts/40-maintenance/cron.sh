#!/bin/bash
# scripts/99-finalization/cron.sh
# Descripción: Gestión de Cron declarativo con validación de seguridad
# Autor: Juan José Hipólito (Refactorizado v2 - Secure Temp Files)

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
readonly SOURCE_FILE="$REPO_ROOT/configs/static/crontabs.txt"
# Usamos mktemp para seguridad (evita colisiones y race conditions)
readonly BACKUP_FILE=$(mktemp /tmp/confiraspa_cron_backup.XXXXXX)
readonly NEW_CRON_FILE=$(mktemp /tmp/confiraspa_cron_new.XXXXXX)

# Trap para limpiar temporales al salir (éxito o error)
cleanup() {
    rm -f "$BACKUP_FILE" "$NEW_CRON_FILE"
}
trap cleanup EXIT

log_section "Configuración de Tareas Programadas (Cron)"

# 1. Validaciones
validate_root

if [ ! -f "$SOURCE_FILE" ]; then
    log_error "No se encuentra el archivo de tareas: $SOURCE_FILE"
    exit 1
fi

# 2. Backup del Cron Actual
log_info "Creando backup del crontab actual..."
# Ignoramos error si no hay cron previo (usuario nuevo)
if crontab -l > "$BACKUP_FILE" 2>/dev/null; then
    log_info "Backup temporal creado."
else
    log_info "No había tareas previas (crontab vacío)."
    # Creamos archivo vacío para evitar errores en restauración
    touch "$BACKUP_FILE"
fi

# 3. Construcción del Nuevo Cron
log_info "Compilando nuevas tareas..."

{
    echo "# --- CRONTAB GESTIONADO POR CONFIRASPA ($(date)) ---"
    echo "# NO EDITAR MANUALMENTE - Modificar configs/static/crontabs.txt"
    echo ""
    cat "$SOURCE_FILE"
    echo "" # Salto de línea final obligatorio POSIX
} > "$NEW_CRON_FILE"

# Seguridad: Solo root puede leer este archivo temporal antes de cargarlo
chmod 600 "$NEW_CRON_FILE"

# 4. Instalación Atómica
log_info "Validando e instalando..."

# Intentamos cargar el nuevo archivo
if crontab "$NEW_CRON_FILE"; then
    log_success "Tareas programadas actualizadas correctamente."
    
    log_info "Resumen de tareas activas:"
    echo "---------------------------------------------------"
    crontab -l | grep -v "^#" | grep -v "^$" | head -n 10
    echo "---------------------------------------------------"
else
    log_error "¡El nuevo crontab es inválido! El sistema lo rechazó."
    log_warning "Restaurando estado anterior..."
    
    if [ -s "$BACKUP_FILE" ]; then
        if crontab "$BACKUP_FILE"; then
            log_success "Backup restaurado correctamente."
        else
            log_error "CRÍTICO: Falló la restauración del backup."
        fi
    else
        # Si estaba vacío, lo borramos
        crontab -r 2>/dev/null || true
        log_warning "Se volvió al estado vacío original."
    fi
    exit 1
fi