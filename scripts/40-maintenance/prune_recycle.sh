#!/usr/bin/env bash
# scripts/40-maintenance/prune_recycle.sh
# Purga periódica de la papelera de reciclaje de Samba (.recycle).
#
# Samba con el módulo recycle mueve los ficheros borrados a .recycle/<usuario>
# en cada share. Sin purga, la papelera crece indefinidamente.
#
# Este script elimina ficheros de la papelera con más de N días de antigüedad
# (por ctime = fecha real de borrado, no de creación del fichero original).
#
# Diseñado para ejecutarse desde cron (semanal o diario) con prioridad baja.

set -euo pipefail
IFS=$'\n\t'

# Cron ejecuta con PATH mínimo. Asegurar rutas estándar.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ===========================================================================
# CABECERA UNIVERSAL
# ===========================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    export REPO_ROOT
fi

source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# LOG_FILE para ejecución desde cron
if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="/var/log/prune_recycle.log"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================

# Días de retención (configurable via .env o --days)
readonly DEFAULT_KEEP_DAYS=30

# Rutas que NUNCA deben procesarse
readonly BLACKLISTED_PATHS=(
    "" "/" "/root" "/home" "/bin" "/etc" "/usr" "/var"
    "/media" "/mnt" "/opt" "/tmp" "/boot" "/dev" "/proc" "/sys"
)

# ===========================================================================
# FUNCIONES LOCALES
# ===========================================================================

on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."
}

parse_args() {
    DRY_RUN="${DRY_RUN:-false}"
    KEEP_DAYS="${PRUNE_RECYCLE_DAYS:-${DEFAULT_KEEP_DAYS}}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN="true" ;;
            --days)
                if [[ -z "${2:-}" || ! "${2}" =~ ^[0-9]+$ || "${2}" -le 0 ]]; then
                    log_error "--days requiere un entero positivo."
                    exit 1
                fi
                KEEP_DAYS="$2"
                shift
                ;;
            *) log_warning "Argumento desconocido: $1" ;;
        esac
        shift
    done
    export DRY_RUN

    readonly KEEP_DAYS
}

# Reduce prioridad de CPU e I/O para no degradar servicios multimedia.
# Se ejecuta directamente porque debe aplicarse incluso en dry-run.
lower_priority() {
    renice -n 19 $$ > /dev/null 2>&1 || true   # Fallo aceptable en cgroups restringidos
    ionice -c 3 -p $$ > /dev/null 2>&1 || true  # Fallo aceptable en kernels sin CFQ
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Verificar que una ruta es segura para operar ---
is_safe_path() {
    local dir="${1%/}"

    local blacklisted
    for blacklisted in "${BLACKLISTED_PATHS[@]}"; do
        if [[ "${dir}" == "${blacklisted}" ]]; then
            return 1
        fi
    done

    # Debe tener al menos 2 niveles de profundidad (ej: /media/WDElements)
    local depth
    depth=$(echo "${dir}" | tr '/' '\n' | grep -c '.')
    if [[ "${depth}" -lt 2 ]]; then
        return 1
    fi

    return 0
}

# --- Construir lista de shares desde el .env ---
build_share_list() {
    local -n shares_ref=$1

    local env_dirs=(
        "${PATH_LIBRARY:-}"
        "${DIR_TORRENTS:-}"
        "${PATH_BACKUP:-}"
    )

    local dir
    for dir in "${env_dirs[@]}"; do
        # || true: si la condición es falsa, el && devuelve 1.
        # Sin el || true, set -e mata al caller si el último dir no existe.
        [[ -n "${dir}" && -d "${dir}" ]] && shares_ref+=("${dir}") || true
    done

    return 0
}

# --- Formatear bytes a unidad legible ---
format_bytes() {
    local bytes="${1:-0}"
    if [[ "${bytes}" -ge 1073741824 ]]; then
        echo "$(( bytes / 1073741824 )) GB"
    elif [[ "${bytes}" -ge 1048576 ]]; then
        echo "$(( bytes / 1048576 )) MB"
    else
        echo "$(( bytes / 1024 )) KB"
    fi
}

# --- Purgar papelera de un share ---
# RISK: Elimina ficheros de .recycle con más de $KEEP_DAYS días.
# Mitigación: solo opera dentro de .recycle (subdirectorio de papelera),
# usa -xdev para no cruzar filesystems, y valida la ruta con is_safe_path.
prune_recycle_dir() {
    local share="$1"
    local recycle_dir="${share}/.recycle"

    if [[ ! -d "${recycle_dir}" ]]; then
        log_info "Sin papelera activa en ${share}."
        return 0
    fi

    log_info "Analizando: ${recycle_dir} (ficheros > ${KEEP_DAYS} días)"

    # Recolectar métricas en una sola pasada de find (evitar doble I/O)
    local file_count=0
    local size_bytes=0
    local file_size

    while IFS= read -r file_path; do
        file_size=$(stat -c%s "${file_path}" 2>/dev/null) || continue
        (( file_count++ )) || true    # (( )) retorna 1 cuando resultado es 0
        (( size_bytes += file_size )) || true  # Idem
    done < <(find "${recycle_dir}" -xdev -type f -ctime +"${KEEP_DAYS}" 2>/dev/null)

    if [[ "${file_count}" -eq 0 ]]; then
        log_info "Nada que limpiar en ${share}."
        return 0
    fi

    local size_readable
    size_readable=$(format_bytes "${size_bytes}")

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Se eliminarían ${file_count} archivos (~${size_readable})."
        return 0
    fi

    # Borrado seguro: -depth procesa de hijos a padres, -xdev no cruza filesystems
    execute_cmd \
        "find '${recycle_dir}' -xdev -depth -type f -ctime +${KEEP_DAYS} -delete" \
        "Purgando ${file_count} archivos (${size_readable}) en ${share}"

    # Limpiar directorios vacíos que quedan tras el borrado
    execute_cmd \
        "find '${recycle_dir}' -xdev -depth -mindepth 1 -type d -empty -delete" \
        "Limpiando directorios vacíos en ${share}"

    log_success "Purga completada en ${share}: ${file_count} archivos (${size_readable})"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Mantenimiento: Purga de Papelera Samba"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands find stat awk

    log_info "Retención: ${KEEP_DAYS} días"

    # --- 2. Prioridad baja ---
    lower_priority

    # --- 3. Construir lista de shares ---
    local -a shares=()
    build_share_list shares

    if [[ ${#shares[@]} -eq 0 ]]; then
        log_warning "No hay shares accesibles. Verifica PATH_LIBRARY, DIR_TORRENTS, PATH_BACKUP en el .env."
        return 0
    fi

    # --- 4. Procesar cada share ---
    local processed=0
    local share

    for share in "${shares[@]}"; do
        if ! is_safe_path "${share}"; then
            log_warning "Ruta insegura omitida: ${share}"
            continue
        fi

        prune_recycle_dir "${share}"
        (( processed++ )) || true  # (( )) retorna 1 cuando resultado es 0
    done

    # --- 5. Resumen ---
    log_success "Purga de papelera finalizada (${processed} shares procesados)."
}

main "$@"
