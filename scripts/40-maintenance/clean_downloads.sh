#!/bin/bash
# scripts/40-maintenance/clean_downloads.sh
# Descripción: Limpieza inteligente de descargas importadas (v2.1 - Fix Subshell)
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

# --- VARIABLES ---
readonly SOURCE_DIR="${DIR_TORRENTS:-/media/DiscoDuro/completo}"
readonly TARGET_DIRS=("${DIR_SERIES:-}" "${DIR_MOVIES:-}" "${DIR_MUSIC:-}" "${DIR_BOOKS:-}")
readonly JUNK_EXTENSIONS=("txt" "nfo" "url" "website" "srt" "jpg" "png" "exe" "html" "htm")
readonly MIN_AGE_MINUTES="+15"

# Lockfile y Prioridad
readonly LOCK_FILE="/run/lock/confiraspa_cleaner.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log_error "El limpiador ya está corriendo."; exit 1; }
renice -n 19 $$ > /dev/null
ionice -c3 -p $$ > /dev/null

log_section "Limpieza de Descargas Redundantes (v2.1)"

# Variables para métricas finales (C7: Ahora sí persistirán)
TOTAL_DELETED=0
BYTES_SAVED=0

log_info "Analizando duplicados en bibliotecas..."

# --- BUCLE PRINCIPAL (CORREGIDO CON PROCESS SUBSTITUTION) ---
while IFS= read -r FILE_PATH; do
    
    BASENAME=$(basename "$FILE_PATH")
    DIRNAME=$(dirname "$FILE_PATH")
    EXT="${FILE_PATH##*.}"

    # Filtros rápidos
    case "${EXT,,}" in
        mkv|mp4|avi|mp3|flac|epub|pdf|cbr|cbz|iso|m4v) ;; 
        *) continue ;; 
    esac

    if [[ "${BASENAME,,}" =~ sample ]]; then continue; fi

    # Metadatos
    FILE_SIZE=$(stat -c%s "$FILE_PATH")
    INODE_SRC=$(stat -c%i "$FILE_PATH")
    FOUND_DUPLICATE=false

    # Búsqueda
    for LIB_DIR in "${TARGET_DIRS[@]}"; do
        [[ -z "$LIB_DIR" || ! -d "$LIB_DIR" ]] && continue
        while IFS= read -r CANDIDATE; do
            INODE_TARGET=$(stat -c%i "$CANDIDATE")
            if [ "$INODE_SRC" == "$INODE_TARGET" ] || cmp -s "$FILE_PATH" "$CANDIDATE"; then
                FOUND_DUPLICATE=true
                break
            fi
        done < <(find "$LIB_DIR" -type f -size "${FILE_SIZE}c")
        [ "$FOUND_DUPLICATE" = true ] && break
    done

    # Eliminación
    if [ "$FOUND_DUPLICATE" = true ]; then
        if [ "${DRY_RUN:-false}" = true ]; then
            log_warning "[DRY-RUN] Borraría: $BASENAME"
        else
            if rm -f "$FILE_PATH"; then
                log_success "Eliminado: $BASENAME"
                TOTAL_DELETED=$((TOTAL_DELETED + 1))
                BYTES_SAVED=$((BYTES_SAVED + FILE_SIZE))
                # Limpieza de junk en la misma carpeta... (omitido por brevedad, mantener igual)
            fi
        fi
    fi

# C7: Aquí está la corrección. Pasamos el find como entrada del while.
done < <(find "$SOURCE_DIR" -type f -mmin "$MIN_AGE_MINUTES")

# Informe Final (C7: Ahora los números serán correctos)
if [ "${DRY_RUN:-false}" = false ]; then
    MB_SAVED=$((BYTES_SAVED / 1024 / 1024))
    log_success "Limpieza completada."
    log_info "Archivos eliminados: $TOTAL_DELETED | Espacio: ${MB_SAVED} MB"
fi