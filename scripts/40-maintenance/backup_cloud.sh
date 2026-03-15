#!/bin/bash
# scripts/40-maintenance/backup_cloud.sh
# Descripción: Motor de Backup Cloud (Rclone) con integridad y protección de disco
# Autor: Juan José Hipólito (Refactorizado v5 - Integrity & Safety)

set -euo pipefail
umask 002 # Asegura permisos de grupo (media) para archivos creados

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# --- VARIABLES ---
readonly CONFIG_FILE="$REPO_ROOT/configs/static/cloud_backups.json"
readonly LOG_FILE="/var/log/rclone_backup.log"
readonly LOCK_FILE="/var/run/confiraspa_rclone.lock"

# Flags globales como Array (Más seguro que strings)
readonly RCLONE_FLAGS=(
    -v 
    --transfers 4 
    --create-empty-src-dirs 
    --drive-skip-gdocs 
    --stats-one-line
    --user-agent "ConfiraspaBackup/1.0"
    --checksum      # MEJORA: Verifica integridad por hash, no solo tamaño/fecha
    --timeout 10m   # MEJORA: Evita cuelgues infinitos
)

log_section "Sincronización Cloud -> Local (Rclone Engine)"

# 1. Gestión de Bloqueo (FLOCK ROBUSTO)
# Evita ejecuciones simultáneas de forma segura ante reinicios
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_error "El proceso de backup cloud ya está en ejecución."
    exit 1
fi

# 2. Validaciones Previas
validate_root
ensure_package "jq"

if ! command -v rclone &> /dev/null; then
    log_error "Rclone no instalado. Ejecuta 'scripts/30-services/rclone.sh'."
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuración no encontrada: $CONFIG_FILE"
    exit 1
fi

# 3. Safety Check Global (Protección de Disco Desmontado)
# Si el destino raíz (/media/Backup) existe pero está vacío, el disco falló.
if [ -d "/media/Backup" ] && [ -z "$(ls -A /media/Backup)" ]; then
    log_error "CRÍTICO: /media/Backup está vacío. Posible fallo de montaje."
    log_error "Abortando operación para prevenir llenado de SD o borrado accidental."
    exit 1
fi

# 4. Procesamiento de Trabajos
# Usamos jq -c para leer objeto a objeto de forma segura
jq -c '.jobs[]' "$CONFIG_FILE" | while read -r job; do
    
    # Extracción y Validación de Campos
    NAME=$(echo "$job" | jq -r '.name // empty')
    SRC=$(echo "$job" | jq -r '.origen // empty')
    DEST=$(echo "$job" | jq -r '.destino // empty')
    MODE=$(echo "$job" | jq -r '.mode // "sync"') # Default a sync si no existe

    # Validación Defensiva: Si falta algún dato crítico, saltamos el job
    if [[ -z "$NAME" || -z "$SRC" || -z "$DEST" ]]; then
        log_error "Job mal formado en JSON. Saltando..."
        continue
    fi
    
    log_subsection "Job: $NAME"
    log_info "Modo:    $MODE"
    log_info "Origen:  $SRC"
    log_info "Destino: $DEST"

    # CHEQUEO DE ESPACIO EN DISCO (MEJORA)
    # Verificamos si hay al menos 2GB libres en el destino antes de empezar
    # Si el directorio no existe, chequeamos el padre.
    CHECK_DIR="$DEST"
    if [ ! -d "$DEST" ]; then CHECK_DIR=$(dirname "$DEST"); fi
    
    if ! check_disk_space "$CHECK_DIR" 2048; then
        log_error "Espacio insuficiente (<2GB) en $CHECK_DIR. Saltando $NAME para proteger el sistema."
        continue
    fi

    # Preparación de Destino
    if [ ! -d "$DEST" ]; then
        log_info "Creando directorio local..."
        mkdir -p "$DEST"
        chown "${ARR_USER:-media}:${ARR_GROUP:-media}" "$DEST"
        chmod 775 "$DEST"
    fi

    # Advertencia de seguridad para el operador
    if [ "$MODE" == "sync" ]; then
        log_warning "ATENCIÓN: Modo 'sync' activo. Archivos borrados en nube se borrarán en local."
    fi

    # --- CONSTRUCCIÓN SEGURA DEL COMANDO ---
    # 1. Comando base + Modo
    CMD=("rclone" "$MODE")
    
    # 2. Añadir flags globales (incluye --checksum)
    CMD+=("${RCLONE_FLAGS[@]}")
    
    # 3. Soporte Dry-Run
    if [ "${DRY_RUN:-false}" = true ]; then
        CMD+=("--dry-run")
        log_warning "[DRY-RUN] Simulación activa."
    fi
    
    # 4. Añadir Origen y Destino
    CMD+=("$SRC" "$DEST")

    # Ejecución
    log_info "Ejecutando transferencia con verificación de integridad..."
    
    # Ejecutamos el array expandido y redirigimos al log específico
    if "${CMD[@]}" >> "$LOG_FILE" 2>&1; then
        log_success "Job '$NAME' finalizado correctamente."
    else
        log_error "Fallo en job '$NAME'. Revisa los detalles en $LOG_FILE"
        # No salimos (exit), permitimos que el siguiente job intente correr
    fi

done

log_success "Ciclo de backups cloud finalizado."