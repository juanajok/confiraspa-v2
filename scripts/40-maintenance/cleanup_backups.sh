#!/usr/bin/env bash
# scripts/40-maintenance/cleanup_backups.sh
# Rotación de backups según políticas de retención definidas en retention.json.
#
# Para cada política, mantiene los N backups más recientes y elimina el resto.
# Incluye protecciones contra borrado accidental de rutas del sistema.
#
# Diseñado para ejecutarse desde cron (domingos 04:30 AM) con prioridad baja.

set -euo pipefail
IFS=$'\n\t'

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

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly CONFIG_FILE="${REPO_ROOT}/configs/static/retention.json"
readonly LOCK_FILE="/run/lock/confiraspa_cleanup.lock"

# Rutas que NUNCA deben limpiarse, aunque aparezcan en el JSON por error
readonly BLACKLISTED_PATHS=(
    "" "/" "/root" "/home" "/bin" "/etc" "/usr" "/var"
    "/media" "/mnt" "/opt" "/tmp" "/boot" "/dev" "/proc" "/sys"
)

# ===========================================================================
# FUNCIONES LOCALES
# ===========================================================================

# --- Error handler ---
on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."
}

# --- Parseo de argumentos ---
parse_args() {
    DRY_RUN="${DRY_RUN:-false}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN="true" ;;
            *) log_warning "Argumento desconocido: $1" ;;
        esac
        shift
    done
    export DRY_RUN
}

# --- Validar comandos del SO base ---
require_system_commands() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Comando requerido del sistema no disponible: ${cmd}"
            exit 1
        fi
    done
}

# --- Adquirir lock exclusivo ---
acquire_lock() {
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        log_error "El script de limpieza ya está en ejecución (lock: ${LOCK_FILE})."
        exit 1
    fi
}

# --- Reducir prioridad ---
lower_priority() {
    renice -n 19 $$ > /dev/null 2>&1 || true
    ionice -c3 -p $$ > /dev/null 2>&1 || true
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Verificar que una ruta no es peligrosa para borrar ---
is_safe_path() {
    local dir="${1%/}"  # Normalizar quitando slash final

    local blacklisted
    for blacklisted in "${BLACKLISTED_PATHS[@]}"; do
        if [[ "${dir}" == "${blacklisted}" ]]; then
            return 1
        fi
    done

    # Debe tener al menos 3 niveles de profundidad (ej: /media/Backup/radarr)
    local depth
    depth=$(echo "${dir}" | tr '/' '\n' | grep -c '.')
    if [[ "${depth}" -lt 3 ]]; then
        return 1
    fi

    return 0
}

# --- Procesar una política de retención ---
process_policy() {
    local name="$1"
    local dir="$2"
    local keep="$3"

    log_subsection "Política: ${name}"

    # A. Validar directorio
    if [[ ! -d "${dir}" ]]; then
        log_warning "Directorio no encontrado: ${dir}. Saltando."
        return 0
    fi

    # B. Validar que la ruta es segura
    if ! is_safe_path "${dir}"; then
        log_error "SEGURIDAD: La ruta '${dir}' está en la lista negra o es demasiado superficial."
        log_error "Abortando esta política para proteger el sistema."
        return 1
    fi

    # C. Validar que 'keep' es un entero positivo
    if ! [[ "${keep}" =~ ^[0-9]+$ ]] || [[ "${keep}" -le 0 ]]; then
        log_warning "Valor de retención inválido ('${keep}'). Se requiere un entero positivo."
        return 1
    fi

    # D. Obtener ficheros ordenados por fecha (más reciente primero)
    local -a all_files
    mapfile -t all_files < <(find "${dir}" -maxdepth 1 -type f -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)

    local total_files=${#all_files[@]}
    log_info "Ruta: ${dir}"
    log_info "Archivos: ${total_files} | Retención: ${keep}"

    if [[ "${total_files}" -le "${keep}" ]]; then
        log_success "Dentro del límite. Sin acciones."
        return 0
    fi

    # E. Eliminar los más antiguos (los que sobran después de los primeros $keep)
    local to_delete_count=$(( total_files - keep ))
    log_info "Eliminando ${to_delete_count} archivos antiguos..."

    # Array slicing: ${array[@]:offset} → desde el índice $keep hasta el final
    local -a files_to_delete=("${all_files[@]:${keep}}")

    local deleted_count=0
    local bytes_saved=0
    local file file_size

    for file in "${files_to_delete[@]}"; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "  [DRY-RUN] Se eliminaría: $(basename "${file}")"
            continue
        fi

        # Capturar tamaño antes de borrar para el resumen
        file_size=$(stat -c%s "${file}" 2>/dev/null) || file_size=0

        if rm -f "${file}"; then
            log_info "  Eliminado: $(basename "${file}")"
            (( deleted_count++ )) || true
            (( bytes_saved += file_size )) || true
        else
            log_error "  Fallo al eliminar: ${file}"
        fi
    done

    # F. Resumen de la política
    if [[ "${DRY_RUN}" != "true" && "${deleted_count}" -gt 0 ]]; then
        local saved_mb=$(( bytes_saved / 1024 / 1024 ))
        log_success "${name}: ${deleted_count} eliminados (${saved_mb} MB liberados)."
    fi

    return 0
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Limpieza y Rotación de Backups (Retention Policy)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands jq find stat rm

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "Configuración no encontrada: ${CONFIG_FILE}"
        exit 1
    fi

    # --- 2. Lock y prioridad baja ---
    acquire_lock
    lower_priority

    # --- 3. Leer políticas del JSON ---
    # 3 campos por política: name, path, keep
    local -a all_fields
    mapfile -t all_fields < <(jq -r '.policies[] | .name, .path, (.keep | tostring)' "${CONFIG_FILE}")

    local total_fields=${#all_fields[@]}
    if [[ "${total_fields}" -eq 0 ]]; then
        log_warning "No hay políticas de retención definidas en el JSON."
        return 0
    fi

    if (( total_fields % 3 != 0 )); then
        log_error "JSON inconsistente (${total_fields} campos, se esperan múltiplos de 3)."
        exit 1
    fi

    # --- 4. Procesar cada política ---
    local i name dir keep
    local policy_count=0
    local fail_count=0

    for (( i=0; i<total_fields; i+=3 )); do
        name="${all_fields[i]:-}"
        dir="${all_fields[i+1]:-}"
        keep="${all_fields[i+2]:-0}"

        if [[ -z "${name}" || -z "${dir}" ]]; then
            log_warning "Política con campos vacíos (posición $((i/3+1))). Saltando."
            continue
        fi

        if process_policy "${name}" "${dir}" "${keep}"; then
            (( policy_count++ )) || true
        else
            (( fail_count++ )) || true
        fi
    done

    # --- 5. Resumen ---
    log_success "Mantenimiento de retención finalizado."
    log_info "  Políticas procesadas: ${policy_count}"
    if [[ "${fail_count}" -gt 0 ]]; then
        log_warning "  Políticas con fallos: ${fail_count}"
    fi
}

main "$@"