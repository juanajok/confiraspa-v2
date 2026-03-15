#!/bin/bash
# scripts/40-maintenance/fix_permissions.sh
# Descripción: Mantenimiento de permisos (Smart Fix) para Cron
# Autor: Juan José Hipólito (Refactorizado para Confiraspa Framework)

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
readonly CONFIG_FILE="$REPO_ROOT/configs/static/permissions.json"

# Usuario y Grupo objetivo (Del .env)
readonly TARGET_USER="${ARR_USER:-media}"
readonly TARGET_GROUP="${ARR_GROUP:-media}"

# Permisos deseados
# Directorios: 775 (rwx rwx r-x) -> Grupo puede escribir/entrar
# Archivos:    664 (rw- rw- r--) -> Grupo puede escribir, NADIE ejecuta (seguridad)
readonly DIR_PERM="775"
readonly FILE_PERM="664"

log_section "Mantenimiento de Permisos (Smart Fix)"

# 1. Construir lista de directorios
# Empezamos con los críticos del NAS definidos en .env
DIRS_TO_FIX=(
    "${DIR_TORRENTS:-}"
    "${DIR_SERIES:-}"
    "${DIR_MOVIES:-}"
    "${DIR_MUSIC:-}"
    "${DIR_BOOKS:-}"
)

# Añadimos extras del JSON si existe
if [ -f "$CONFIG_FILE" ]; then
    if ensure_package "jq" >/dev/null; then
        # Leemos el array JSON en un array Bash
        while IFS='' read -r line; do DIRS_TO_FIX+=("$line"); done < <(jq -r '.extra_dirs[]' "$CONFIG_FILE")
    fi
fi

# 2. Bucle de Mantenimiento
log_info "Objetivo: ${TARGET_USER}:${TARGET_GROUP} | Dirs: $DIR_PERM | Files: $FILE_PERM"

for DIR in "${DIRS_TO_FIX[@]}"; do
    # Saltar si la variable estaba vacía o directorio no existe
    if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
        continue
    fi

    log_subsection "Analizando: $DIR"

    # A. Corregir Propietario (Owner/Group)
    # find busca archivos que NO pertenezcan al usuario O al grupo correcto
    # -exec chown los arregla por lotes (+)
    log_info "  -> Verificando propietarios incorrectos..."
    find "$DIR" \
        \( ! -user "$TARGET_USER" -o ! -group "$TARGET_GROUP" \) \
        -print -exec chown "$TARGET_USER:$TARGET_GROUP" {} + | wc -l | xargs -I {} echo "     Corregidos: {}"

    # B. Corregir Permisos de Directorios (775)
    log_info "  -> Verificando directorios con permisos erróneos..."
    find "$DIR" -type d ! -perm "$DIR_PERM" \
        -print -exec chmod "$DIR_PERM" {} + | wc -l | xargs -I {} echo "     Corregidos: {}"

    # C. Corregir Permisos de Archivos (664)
    # Nota: Esto quita el flag de ejecución (+x) a los archivos normales, lo cual es bueno para seguridad
    log_info "  -> Verificando archivos con permisos erróneos..."
    find "$DIR" -type f ! -perm "$FILE_PERM" \
        -print -exec chmod "$FILE_PERM" {} + | wc -l | xargs -I {} echo "     Corregidos: {}"

done

log_success "Mantenimiento de permisos finalizado."