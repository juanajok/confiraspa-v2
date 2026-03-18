#!/bin/bash
# scripts/40-maintenance/cleanup_backups.sh
# Descripción: Rotación de backups con protecciones Enterprise (v2)
# Autor: Juan José Hipólito (Refactorizado v2 - Safety First)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# --- VARIABLES Y LOCKING ---
readonly CONFIG_FILE="$REPO_ROOT/configs/static/retention.json"
readonly LOCK_FILE="/run/lock/confiraspa_cleanup.lock"

# Evitar ejecución concurrente (Locking)
exec 200>"$LOCK_FILE"
flock -n 200 || { log_error "El script de limpieza ya está en ejecución."; exit 1; }

# --- FUNCIONES DE SEGURIDAD ---

# Verifica si una ruta es peligrosa para borrar
is_safe_path() {
    local dir="$1"
    # Normalizamos ruta quitando slash final
    dir="${dir%/}"
    
    case "$dir" in
        ""|"/"|"/root"|"/home"|"/bin"|"/etc"|"/usr"|"/var"|"/media"|"/mnt")
            return 1 ;;
        *) 
            return 0 ;;
    esac
}

log_section "Limpieza y Rotación de Backups (Retention Policy v2)"

# 1. Validaciones
validate_root
ensure_package "jq"

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuración no encontrada: $CONFIG_FILE"
    exit 1
fi

# 2. Procesamiento de Políticas
# Leemos el JSON completo
jq -c '.policies[]' "$CONFIG_FILE" | while read -r policy; do
    
    NAME=$(echo "$policy" | jq -r '.name')
    DIR=$(echo "$policy" | jq -r '.path')
    KEEP=$(echo "$policy" | jq -r '.keep')

    log_subsection "Política: $NAME"
    
    # A. Validaciones de Integridad
    if [ ! -d "$DIR" ]; then
        log_warning "Directorio no encontrado: $DIR (Saltando)"
        continue
    fi

    # B. Validación de Seguridad de Ruta (CRÍTICO)
    if ! is_safe_path "$DIR"; then
        log_error "SEGURIDAD: La ruta '$DIR' está en la lista negra. ABORTANDO para proteger el sistema."
        continue
    fi

    # C. Validación Numérica de 'Keep'
    if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -le 0 ]; then
        log_warning "Valor de retención inválido ('$KEEP'). Se requiere un entero positivo."
        continue
    fi

    # 3. Obtención de Archivos (Método Robusto 'find')
    # find: busca archivos (-type f), maxdepth 1 (no recursivo)
    # printf: imprime "timestamp[TAB]ruta"
    # sort -nr: ordena numéricamente reverso (más nuevo primero)
    # cut: se queda solo con la ruta
    mapfile -t ALL_FILES < <(find "$DIR" -maxdepth 1 -type f -printf '%T@\t%p\n' | sort -nr | cut -f2-)
    
    TOTAL_FILES="${#ALL_FILES[@]}"
    log_info "Ruta: $DIR"
    log_info "Archivos encontrados: $TOTAL_FILES | Política: Mantener $KEEP"

    if [ "$TOTAL_FILES" -le "$KEEP" ]; then
        log_success "Dentro del límite. No se requieren acciones."
        continue
    fi

    # 4. Cálculo de Eliminación
    TO_DELETE_COUNT=$((TOTAL_FILES - KEEP))
    log_info "Limpiando $TO_DELETE_COUNT archivos antiguos..."

    # Array Slicing: ${array[@]:offset} -> Cogemos desde el índice KEEP hasta el final
    # (Los primeros 0..KEEP-1 son los nuevos que guardamos)
    FILES_TO_DELETE=("${ALL_FILES[@]:$KEEP}")

    DELETED_COUNT=0
    
    for file in "${FILES_TO_DELETE[@]}"; do
        if [ "${DRY_RUN:-false}" = true ]; then
            log_warning "[DRY-RUN] Se eliminaría: $(basename "$file")"
        else
            # Borrado protegido
            if rm -f "$file"; then
                log_info "Eliminado: $(basename "$file")"
                ((DELETED_COUNT++))
            else
                log_error "Fallo al eliminar: $file"
            fi
        fi
    done

    if [ "${DRY_RUN:-false}" = false ]; then
        log_success "Resumen: $DELETED_COUNT archivos eliminados en $NAME."
    fi

done

log_success "Mantenimiento de retención finalizado."