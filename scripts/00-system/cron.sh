#!/usr/bin/env bash
# scripts/40-maintenance/cron.sh
# Configuración idempotente de tareas programadas para Confiraspa.
#
# Lee crontabs.txt, sustituye ${CONFIRASPA_ROOT} por la ruta real del repo,
# e instala el resultado como crontab de root. Usa marcadores BEGIN/END
# para gestionar solo el bloque de Confiraspa sin tocar tareas externas
# que el usuario haya añadido manualmente.
#
# Fix C8 del análisis original: el crontabs.txt ya no usa rutas hardcodeadas
# a /opt/confiraspa — usa ${CONFIRASPA_ROOT} como placeholder.

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
readonly SOURCE_FILE="${REPO_ROOT}/configs/static/crontabs.txt"
readonly MARKER_BEGIN="# BEGIN CONFIRASPA MANAGED BLOCK"
readonly MARKER_END="# END CONFIRASPA MANAGED BLOCK"

# ===========================================================================
# FUNCIONES LOCALES
# ===========================================================================

# --- Error handler ---
on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."

    # Restaurar crontab si teníamos backup
    if [[ -n "${backup_file:-}" && -s "${backup_file:-}" ]]; then
        crontab "${backup_file}" 2>/dev/null || true
        log_warning "Crontab anterior restaurado desde backup."
    fi
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

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Renderizar el bloque de crontab con rutas reales ---
render_cron_block() {
    local temp_dir="$1"
    local rendered="${temp_dir}/confiraspa_cron_block.txt"

    export CONFIRASPA_ROOT="${REPO_ROOT}"

    {
        echo "${MARKER_BEGIN}"
        envsubst '${CONFIRASPA_ROOT}' < "${SOURCE_FILE}"
        echo "${MARKER_END}"
    } > "${rendered}"

    echo "${rendered}"
}

# --- Obtener el crontab actual sin el bloque de Confiraspa ---
# Preserva las tareas que el usuario haya añadido manualmente.
get_external_crontab() {
    local temp_dir="$1"
    local external="${temp_dir}/external_cron.txt"

    # Capturar crontab actual (puede estar vacío o no existir)
    local current="${temp_dir}/current_cron.txt"
    crontab -l > "${current}" 2>/dev/null || true

    # Extraer todo lo que NO esté entre los marcadores BEGIN/END
    awk -v begin="${MARKER_BEGIN}" -v end="${MARKER_END}" '
        $0 == begin { skip=1; next }
        $0 == end   { skip=0; next }
        !skip       { print }
    ' "${current}" > "${external}"

    echo "${external}"
}

# --- Construir el crontab candidato completo ---
build_candidate() {
    local temp_dir="$1"
    local candidate="${temp_dir}/candidate_cron.txt"

    local external_file
    external_file=$(get_external_crontab "${temp_dir}")

    local block_file
    block_file=$(render_cron_block "${temp_dir}")

    # Combinar: tareas externas + bloque Confiraspa
    {
        # Tareas externas (si las hay)
        if [[ -s "${external_file}" ]]; then
            cat "${external_file}"
            echo ""
        fi
        # Bloque gestionado
        cat "${block_file}"
        echo ""
    } > "${candidate}"

    echo "${candidate}"
}

# --- Extraer solo el bloque Confiraspa del crontab actual para comparar ---
get_current_block() {
    local temp_dir="$1"
    local current_block="${temp_dir}/current_block.txt"

    crontab -l 2>/dev/null | awk -v begin="${MARKER_BEGIN}" -v end="${MARKER_END}" '
        $0 == begin { found=1 }
        found       { print }
        $0 == end   { exit }
    ' > "${current_block}" || true

    echo "${current_block}"
}

# --- Instalar crontab si el bloque ha cambiado (idempotente) ---
install_crontab_if_changed() {
    local temp_dir="$1"

    local new_block
    new_block=$(render_cron_block "${temp_dir}")

    local current_block
    current_block=$(get_current_block "${temp_dir}")

    # Comparar solo el bloque gestionado — ignora cambios en tareas externas
    if [[ -s "${current_block}" ]] && cmp -s "${new_block}" "${current_block}"; then
        log_info "Tareas programadas sin cambios."
        return 1
    fi

    # Hay cambios — construir crontab completo e instalar
    local candidate
    candidate=$(build_candidate "${temp_dir}")

    # Validación básica: el candidato debe tener al menos una línea con un schedule
    if ! grep -qE '^[0-9*]' "${candidate}"; then
        log_error "El crontab candidato no contiene ninguna tarea válida."
        return 1
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Se instalarían las siguientes tareas:"
        grep -v "^#" "${candidate}" | grep -v "^$" | while IFS= read -r line; do
            log_info "  ${line}"
        done
        return 0
    fi

    # Backup del crontab actual para rollback en on_error
    backup_file="${temp_dir}/crontab_backup.txt"
    crontab -l > "${backup_file}" 2>/dev/null || true

    if crontab "${candidate}"; then
        log_success "Tareas programadas instaladas."
        return 0
    else
        log_error "Error al instalar crontab."
        # Rollback
        if [[ -s "${backup_file}" ]]; then
            crontab "${backup_file}" 2>/dev/null || true
            log_warning "Crontab anterior restaurado."
        fi
        return 1
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    local temp_dir=""
    local backup_file=""

    trap 'rm -rf "${temp_dir:-}"' EXIT
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Configuración de Tareas Programadas (Cron)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands crontab envsubst awk grep

    if [[ ! -f "${SOURCE_FILE}" ]]; then
        log_error "Plantilla de crontab no encontrada: ${SOURCE_FILE}"
        exit 1
    fi

    # --- 2. Generar e instalar ---
    temp_dir="$(mktemp -d)"

    log_info "Ruta del repositorio: ${REPO_ROOT}"

    install_crontab_if_changed "${temp_dir}"

    # --- 3. Mostrar resultado ---
    if [[ "${DRY_RUN}" != "true" ]]; then
        log_info "Tareas programadas activas:"
        crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | while IFS= read -r line; do
            log_info "  ${line}"
        done
    fi
}

main "$@"