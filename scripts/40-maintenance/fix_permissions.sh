#!/bin/bash
# scripts/40-maintenance/fix_permissions.sh
# Descripción: Mantenimiento de permisos (Smart Fix) para Cron
# Autor: Juan José Hipólito (Refactorizado v5 - Entorno Seguro)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"

# --- VARIABLES ---
readonly CONFIG_FILE="$REPO_ROOT/configs/static/permissions.json"
TARGET_USER="${ARR_USER:-media}"
TARGET_GROUP="${ARR_GROUP:-media}"
readonly DIR_PERM="775"
readonly FILE_PERM="664"

log_section "Mantenimiento de Permisos (Smart Fix)"

# --- VALIDACIÓN DE IDENTIDAD (FIX PARA DRY-RUN) ---
if ! id "$TARGET_USER" &>/dev/null; then
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "[DRY-RUN] El usuario '$TARGET_USER' no existe. Se simulará la ejecución sin lanzar 'find'."
        log_success "Mantenimiento de permisos finalizado (Simulado)."
        exit 0
    else
        log_error "El usuario '$TARGET_USER' no existe en el sistema. ¿Se ejecutó la etapa 10-users?"
        exit 1
    fi
fi

# 1. Construir lista de directorios
DIRS_TO_FIX=(
    "${DIR_TORRENTS:-}"
    "${DIR_SERIES:-}"
    "${DIR_MOVIES:-}"
    "${DIR_MUSIC:-}"
    "${DIR_BOOKS:-}"
)

# Añadimos extras del JSON si existe
if [ -f "$CONFIG_FILE" ]; then
    if command -v jq &> /dev/null; then
        # Leemos el array JSON de forma segura
        while read -r line; do 
            [[ -n "$line" ]] && DIRS_TO_FIX+=("$line")
        done < <(jq -r '.extra_dirs[]' "$CONFIG_FILE" 2>/dev/null || echo "")
    fi
fi

# 2. Bucle de Mantenimiento
log_info "Objetivo: ${TARGET_USER}:${TARGET_GROUP} | Dirs: $DIR_PERM | Files: $FILE_PERM"

for DIR in "${DIRS_TO_FIX[@]}"; do
    if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
        continue
    fi

    log_subsection "Analizando: $DIR"

    # A. Corregir Propietario
    log_info " -> Verificando propietarios..."
    # Usamos execute_cmd para que la acción de cambio sea trazable
    # pero el conteo (find ... | wc) lo hacemos directo por ser de solo lectura
    MISSING_OWNER=$(find "$DIR" \( ! -user "$TARGET_USER" -o ! -group "$TARGET_GROUP" \) | wc -l)
    
    if [ "$MISSING_OWNER" -gt 0 ]; then
        execute_cmd "Corrigiendo $MISSING_OWNER propietarios en $DIR" \
            "chown -R $TARGET_USER:$TARGET_GROUP $DIR"
    else
        log_info "    Propietarios correctos."
    fi

    # B. Corregir Permisos de Directorios
    log_info " -> Verificando directorios..."
    ERR_DIRS=$(find "$DIR" -type d ! -perm "$DIR_PERM" | wc -l)
    if [ "$ERR_DIRS" -gt 0 ]; then
        execute_cmd "Corrigiendo $ERR_DIRS directorios en $DIR" \
            "find $DIR -type d ! -perm $DIR_PERM -exec chmod $DIR_PERM {} +"
    else
        log_info "    Directorios correctos."
    fi

    # C. Corregir Permisos de Archivos
    log_info " -> Verificando archivos..."
    ERR_FILES=$(find "$DIR" -type f ! -perm "$FILE_PERM" | wc -l)
    if [ "$ERR_FILES" -gt 0 ]; then
        execute_cmd "Corrigiendo $ERR_FILES archivos en $DIR" \
            "find $DIR -type f ! -perm $FILE_PERM -exec chmod $FILE_PERM {} +"
    else
        log_info "    Archivos correctos."
    fi
done

log_success "Mantenimiento de permisos finalizado."