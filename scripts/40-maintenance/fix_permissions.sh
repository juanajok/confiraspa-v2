#!/usr/bin/env bash
# scripts/40-maintenance/fix_permissions.sh
# Mantenimiento idempotente de permisos para directorios multimedia.
#
# Este script se ejecuta tanto desde install.sh como desde cron (semanalmente).
# Asegura que todos los directorios multimedia tienen el propietario y permisos
# correctos para que los servicios *Arr, Plex y Samba funcionen sin conflictos.
#
# NOTA: Solo aplica FILE_PERM a ficheros que NO tienen el bit de ejecución.
# Esto evita quitar +x a scripts auxiliares que puedan existir en los
# directorios monitorizados (bug M8 del análisis original).

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
readonly CONFIG_FILE="${REPO_ROOT}/configs/static/permissions.json"
readonly DIR_PERM="775"
readonly FILE_PERM="664"

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

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Construir lista de directorios a monitorizar ---
build_directory_list() {
    local -n dirs_ref=$1

    # Directorios del .env (pueden estar vacíos si no se definieron)
    local env_dirs=(
        "${DIR_TORRENTS:-}"
        "${DIR_SERIES:-}"
        "${DIR_MOVIES:-}"
        "${DIR_MUSIC:-}"
        "${DIR_BOOKS:-}"
    )

    local dir
    for dir in "${env_dirs[@]}"; do
        [[ -n "${dir}" ]] && dirs_ref+=("${dir}")
    done

    # Directorios adicionales desde JSON (si existe y jq está disponible)
    if [[ -f "${CONFIG_FILE}" ]] && command -v jq &>/dev/null; then
        while IFS= read -r line; do
            [[ -n "${line}" ]] && dirs_ref+=("${line}")
        done < <(jq -r '.extra_dirs[]' "${CONFIG_FILE}" 2>/dev/null || true)
    fi
}

# --- Corregir propietarios de un directorio ---
fix_ownership() {
    local dir="$1"
    local target_user="$2"
    local target_group="$3"

    log_info "  -> Verificando propietarios..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "  [DRY-RUN] Verificaría propietarios en ${dir}"
        return 0
    fi

    local bad_count
    bad_count=$(find "${dir}" \( ! -user "${target_user}" -o ! -group "${target_group}" \) 2>/dev/null | wc -l)

    if [[ "${bad_count}" -gt 0 ]]; then
        execute_cmd "chown -R '${target_user}:${target_group}' '${dir}'" \
            "Corrigiendo ${bad_count} propietarios en ${dir}"
    else
        log_info "     Propietarios correctos."
    fi
}

# --- Corregir permisos de directorios ---
fix_dir_permissions() {
    local dir="$1"

    log_info "  -> Verificando permisos de directorios..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "  [DRY-RUN] Verificaría permisos de directorios en ${dir}"
        return 0
    fi

    local bad_count
    bad_count=$(find "${dir}" -type d ! -perm "${DIR_PERM}" 2>/dev/null | wc -l)

    if [[ "${bad_count}" -gt 0 ]]; then
        execute_cmd "find '${dir}' -type d ! -perm '${DIR_PERM}' -exec chmod '${DIR_PERM}' {} +" \
            "Corrigiendo ${bad_count} directorios en ${dir}"
    else
        log_info "     Directorios correctos."
    fi
}

# --- Corregir permisos de archivos ---
# IMPORTANTE: Solo aplica a ficheros SIN bit de ejecución.
# Esto preserva el +x de scripts auxiliares que puedan existir en
# directorios multimedia (ej: scripts de post-procesamiento de Sonarr).
fix_file_permissions() {
    local dir="$1"

    log_info "  -> Verificando permisos de archivos..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "  [DRY-RUN] Verificaría permisos de archivos en ${dir}"
        return 0
    fi

    # Solo ficheros que NO son ejecutables y tienen permisos incorrectos
    local bad_count
    bad_count=$(find "${dir}" -type f ! -executable ! -perm "${FILE_PERM}" 2>/dev/null | wc -l)

    if [[ "${bad_count}" -gt 0 ]]; then
        execute_cmd "find '${dir}' -type f ! -executable ! -perm '${FILE_PERM}' -exec chmod '${FILE_PERM}' {} +" \
            "Corrigiendo ${bad_count} archivos en ${dir}"
    else
        log_info "     Archivos correctos."
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Mantenimiento de Permisos (Smart Fix)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands find chown chmod id wc

    local target_user="${ARR_USER:-media}"
    local target_group="${ARR_GROUP:-media}"

    # Validar que el usuario/grupo de destino existe
    if ! id "${target_user}" &>/dev/null; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "[DRY-RUN] Usuario '${target_user}' no existe (normal en simulación)."
            log_success "Mantenimiento de permisos finalizado (simulado)."
            return 0
        else
            log_error "Usuario '${target_user}' no existe. ¿Se ejecutó 10-users.sh?"
            exit 1
        fi
    fi

    # --- 2. Construir lista de directorios ---
    local dirs_to_fix=()
    build_directory_list dirs_to_fix

    if [[ ${#dirs_to_fix[@]} -eq 0 ]]; then
        log_warning "No hay directorios configurados para monitorizar."
        return 0
    fi

    log_info "Objetivo: ${target_user}:${target_group} | Dirs: ${DIR_PERM} | Files: ${FILE_PERM}"

    # --- 3. Bucle de mantenimiento ---
    local dir
    for dir in "${dirs_to_fix[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            log_warning "Directorio no encontrado, saltando: ${dir}"
            continue
        fi

        log_subsection "Analizando: ${dir}"

        fix_ownership "${dir}" "${target_user}" "${target_group}"
        fix_dir_permissions "${dir}"
        fix_file_permissions "${dir}"
    done

    log_success "Mantenimiento de permisos finalizado."
}

main "$@"