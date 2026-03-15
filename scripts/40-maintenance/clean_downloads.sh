#!/bin/bash
# scripts/40-maintenance/clean_downloads.sh
# Descripción: Limpieza inteligente de descargas importadas (v2 - High Performance)
# Autor: Juan José Hipólito (Refactorizado v2 - Post Peer Review)

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
readonly TARGET_DIRS=(
    "${DIR_SERIES:-}"
    "${DIR_MOVIES:-}"
    "${DIR_MUSIC:-}"
    "${DIR_BOOKS:-}"
)

# Extensiones basura a eliminar (Junk)
readonly JUNK_EXTENSIONS=("txt" "nfo" "url" "website" "srt" "jpg" "png" "exe" "html" "htm")

# Configuración de Seguridad
readonly MIN_AGE_MINUTES="+15" # Solo archivos con más de 15 min de antigüedad

# Lockfile
readonly LOCK_FILE="/run/lock/confiraspa_cleaner.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { log_error "El limpiador ya está corriendo."; exit 1; }

# Optimización I/O (RPi Friendly)
renice -n 19 $$ > /dev/null
ionice -c3 -p $$ > /dev/null

log_section "Limpieza de Descargas Redundantes (v2)"

# 1. Validaciones
validate_root
if [ ! -d "$SOURCE_DIR" ]; then
    log_error "El directorio de descargas no existe: $SOURCE_DIR"
    exit 1
fi

# Variables para métricas finales
TOTAL_DELETED=0
BYTES_SAVED=0

log_info "Analizando: $SOURCE_DIR"
log_info "Criterio: Archivos > $MIN_AGE_MINUTES min de antigüedad."

# 2. Bucle Principal Optimizado (Process Substitution)
# Evita subshell para mantener variables y control de errores
while IFS= read -r FILE_PATH; do
    
    BASENAME=$(basename "$FILE_PATH")
    DIRNAME=$(dirname "$FILE_PATH")
    
    # A. Filtro de Extensión (Case nativo rápido)
    EXT="${FILE_PATH##*.}"
    case "${EXT,,}" in
        mkv|mp4|avi|mp3|flac|epub|pdf|cbr|cbz|iso|m4v) ;; # OK
        *) continue ;; # Saltar si no es media
    esac

    # B. Filtro de Seguridad (Samples)
    if [[ "${BASENAME,,}" =~ sample ]]; then
        # log_debug "Saltando posible sample: $BASENAME"
        continue
    fi

    # C. Obtención de Metadatos (Una sola vez)
    FILE_SIZE=$(stat -c%s "$FILE_PATH")
    INODE_SRC=$(stat -c%i "$FILE_PATH")
    FOUND_DUPLICATE=false

    # 3. Búsqueda en Bibliotecas
    for LIB_DIR in "${TARGET_DIRS[@]}"; do
        [[ -z "$LIB_DIR" || ! -d "$LIB_DIR" ]] && continue

        # Buscamos candidatos con el mismo tamaño exacto
        while IFS= read -r CANDIDATE; do
            # 1. Check Rápido: Inodo (Hardlink)
            INODE_TARGET=$(stat -c%i "$CANDIDATE")
            if [ "$INODE_SRC" == "$INODE_TARGET" ]; then
                log_info "  [Hardlink Detectado] $BASENAME"
                FOUND_DUPLICATE=true
                break
            fi

            # 2. Check Lento: Comparación Binaria
            # Solo si no son hardlinks (son archivos diferentes fisicamente)
            if cmp -s "$FILE_PATH" "$CANDIDATE"; then
                log_info "  [Copia Detectada] $BASENAME coincide con biblioteca."
                FOUND_DUPLICATE=true
                break
            fi
        done < <(find "$LIB_DIR" -type f -size "${FILE_SIZE}c")
        
        if [ "$FOUND_DUPLICATE" = true ]; then break; fi
    done

    # 4. Eliminación y Limpieza
    if [ "$FOUND_DUPLICATE" = true ]; then
        if [ "${DRY_RUN:-false}" = true ]; then
            log_warning "[DRY-RUN] Se eliminaría: $FILE_PATH"
        else
            if rm -f "$FILE_PATH"; then
                log_success "Eliminado: $FILE_PATH"
                ((TOTAL_DELETED++))
                BYTES_SAVED=$((BYTES_SAVED + FILE_SIZE))
                
                # 5. Limpieza Colateral (Junk Files en la misma carpeta)
                # Solo si la carpeta no es la raíz de descargas
                if [ "$DIRNAME" != "$SOURCE_DIR" ]; then
                    for junk in "${DIRNAME}"/*; do
                        [ ! -f "$junk" ] && continue
                        
                        J_EXT="${junk##*.}"
                        # Check si la extensión está en la lista negra
                        for valid_junk in "${JUNK_EXTENSIONS[@]}"; do
                            if [[ "${J_EXT,,}" == "$valid_junk" ]]; then
                                rm -f "$junk"
                                # log_info "     Residuo eliminado: $(basename "$junk")"
                                break
                            fi
                        done
                    done
                fi
            else
                log_error "Fallo al eliminar: $FILE_PATH"
            fi
        fi
    fi

# find filters: type file, modified > 15 mins ago
done < <(find "$SOURCE_DIR" -type f -mmin "$MIN_AGE_MINUTES")

# 6. Limpieza Final de Carpetas Vacías
log_info "Limpiando directorios vacíos..."
if [ "${DRY_RUN:-false}" = true ]; then
    find "$SOURCE_DIR" -mindepth 1 -type d -empty -print | sed 's/^/[DRY-RUN] Empty dir: /'
else
    find "$SOURCE_DIR" -mindepth 1 -type d -empty -delete
fi

# 7. Informe Final
if [ "${DRY_RUN:-false}" = false ]; then
    MB_SAVED=$((BYTES_SAVED / 1024 / 1024))
    log_success "Limpieza completada."
    log_info "---------------------------------------------------"
    log_info "Archivos eliminados: $TOTAL_DELETED"
    log_info "Espacio recuperado:  ${MB_SAVED} MB"
    log_info "---------------------------------------------------"
fi