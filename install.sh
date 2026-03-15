#!/bin/bash
# install.sh
# Descripción: Orquestador Principal del Framework Confiraspa
# Versión: 2.3 (Gold Master - Dump Aligned)
# Uso: sudo ./install.sh [--dry-run] [--only <nombre_script>]

set -euo pipefail
IFS=$'\n\t'

# --- 1. Bootstrap de Entorno y Variables ---
export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOST_IP=$(hostname -I | awk '{print $1}')
export DRY_RUN=false

# Carga de librerías
source "$REPO_ROOT/lib/colors.sh"
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"

# Configuración de Logs y Locking
LOG_FILE="$REPO_ROOT/logs/install_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/var/lock/confiraspa.lock"
TARGET_SCRIPT=""

# --- 2. Gestión de Bloqueo (Flock Robust) ---
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo -e "\033[0;31m[CRITICAL]\033[0m El instalador ya se está ejecutando (Lock activo)."
    exit 1
fi

# --- 3. Parsing de Argumentos ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) export DRY_RUN=true; shift ;;
        --only)    TARGET_SCRIPT="$2"; shift 2 ;;
        *)         log_error "Argumento desconocido: $1"; exit 1 ;;
    esac
done

# --- 4. Inicialización ---
init_logging "$LOG_FILE"
log_header "Iniciando Confiraspa Framework v2.3"
log_info "IP Detectada: $HOST_IP"
log_info "Log de sesión: $LOG_FILE"

validate_root
if [ ! -f "$REPO_ROOT/.env" ]; then
    log_error "Falta el archivo .env. Copia .env.example y configúralo."
    exit 1
fi

# Cargar variables globales automáticamente
set -a
source "$REPO_ROOT/.env"
set +a

# --- 5. DEFINICIÓN DE ETAPAS (Dependency Order) ---
# Orden basado en tu Dump: System -> Network -> Libs -> Services -> Maintenance
STAGES=(
    # --- 00 SYSTEM ---
    "scripts/00-system/00-update.sh"
    "scripts/00-system/10-users.sh"
    "scripts/00-system/20-storage.sh"

    # --- 10 NETWORK ---
    "scripts/10-network/00-static-ip.sh" # (Si existe)
    "scripts/10-network/firewall.sh"
    "scripts/10-network/10-xrdp.sh"
    "scripts/10-network/20-vnc.sh"

    # --- 20 LIBS (Detectado en dump) ---
    #lib/install_mono.sh"

    # --- 30 SERVICES (CORE) ---
    "scripts/30-services/samba.sh"
    "scripts/30-services/rclone.sh"
    "scripts/30-services/rsync.sh"

    # --- 30 SERVICES (APPS) ---
    "scripts/30-services/transmission.sh"
    "scripts/30-services/arr_suite.sh"
    "scripts/30-services/sonarr.sh"
    "scripts/30-services/bazarr.sh"
    "scripts/30-services/calibre.sh"
    "scripts/30-services/plex.sh"
    "scripts/30-services/amule.sh"
    "scripts/30-services/webmin.sh"

    # --- 40 MAINTENANCE (Unificado) ---
    # Configuración de tareas recurrentes
    "scripts/40-maintenance/cron.sh"
    "scripts/40-maintenance/logrotate.sh"
    "scripts/40-maintenance/fix_permissions.sh"
    
    # Scripts de backup/limpieza (Ejecución inicial opcional)
    # Se ejecutarán via cron, pero podemos testearlos aquí si se desea.
    # "scripts/40-maintenance/backup_rsync.sh"
    # "scripts/40-maintenance/backup_cloud.sh"
    # "scripts/40-maintenance/cleanup_backups.sh"
    # "scripts/40-maintenance/clean_downloads.sh"
)

# --- 6. EJECUCIÓN DEL PIPELINE ---
EXECUTED_COUNT=0

for script_rel_path in "${STAGES[@]}"; do
    script_path="$REPO_ROOT/$script_rel_path"
    script_name=$(basename "$script_path" .sh)

    # A. Filtro --only
    if [[ -n "$TARGET_SCRIPT" && "$script_name" != *"$TARGET_SCRIPT"* ]]; then
        continue
    fi

    # B. Verificar existencia
    if [[ ! -f "$script_path" ]]; then
        # Solo avisamos si se pidió explícitamente, sino silencioso para opcionales
        if [[ -n "$TARGET_SCRIPT" ]]; then
            log_warning "Script solicitado no encontrado: $script_rel_path"
        else
            log_debug "Saltando script opcional no encontrado: $script_name"
        fi
        continue
    fi

    # C. Preparación
    log_section "Etapa: $script_name"
    chmod +x "$script_path"
    EXECUTED_COUNT=$((EXECUTED_COUNT + 1))

    # D. Ejecución con Trazabilidad
    SCRIPT_ARGS=""
    if [ "$DRY_RUN" = true ]; then SCRIPT_ARGS="--dry-run"; fi

    set +e
    # Pipefail está activo globalmente, así que si el script falla, el pipe falla
    "$script_path" $SCRIPT_ARGS 2>&1 | tee -a "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
    set -e

    # E. Gestión de Errores
    if [ $EXIT_CODE -eq 0 ]; then
        log_success "Etapa '$script_name' completada."
    else
        log_error "FALLO CRÍTICO en etapa '$script_name' (Exit Code: $EXIT_CODE)."
        log_error "Revisa el log: $LOG_FILE"
        echo "---------------------------------------------------"
        tail -n 10 "$LOG_FILE" | grep -v "^\["
        echo "---------------------------------------------------"
        exit 1
    fi
done

# --- 7. CIERRE ---
if [ "$EXECUTED_COUNT" -eq 0 ]; then
    if [ -n "$TARGET_SCRIPT" ]; then
        log_error "No se encontró ningún script que coincida con: '$TARGET_SCRIPT'"
        exit 1
    else
        log_warning "No se ejecutó ningún script."
    fi
fi

log_header "¡Instalación Finalizada con Éxito! 🚀"
log_info "Resumen de Infraestructura:"
log_info "  - IP Servidor: $HOST_IP"
log_info "  - Webmin:      https://$HOST_IP:10000"
log_info "  - Plex:        http://$HOST_IP:32400/web"
log_info "  - Logs:        $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    log_warning "[DRY-RUN] Simulación finalizada. No se aplicaron cambios."
else
    log_warning "RECOMENDACIÓN FINAL: Reinicia la Raspberry Pi para aplicar todos los cambios."
fi