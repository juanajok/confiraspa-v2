#!/usr/bin/env bash
# scripts/00-system/20-storage.sh
# Configuración idempotente de almacenamiento y permisos

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly MOUNTS_CONFIG="${REPO_ROOT}/configs/static/mounts.json"
readonly FSTAB_FILE="/etc/fstab"
readonly FSTAB_BEGIN_MARKER="# BEGIN CONFIRASPA MANAGED MOUNTS"
readonly FSTAB_END_MARKER="# END CONFIRASPA MANAGED MOUNTS"

DRY_RUN=false
FSTAB_BACKUP=""

source "${REPO_ROOT}/lib/colors.sh"
source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

# Cargar .env si no estamos bajo install.sh (ej: --only 20-storage)
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# =============================================================================
# MANEJO DE ERRORES
#
# BASH_LINENO[0] contiene la línea real del error; ${LINENO} en el trap
# apuntaría a la línea del propio trap.
# =============================================================================
on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."

    # Restaurar fstab si teníamos backup y no estamos en dry-run.
    # '|| true' es deliberado: si la restauración falla, no ocultamos el error original.
    if [[ -n "${FSTAB_BACKUP}" && -f "${FSTAB_BACKUP}" && "${DRY_RUN}" != "true" ]]; then
        log_warning "Restaurando backup de fstab: ${FSTAB_BACKUP}"
        cp -f "${FSTAB_BACKUP}" "${FSTAB_FILE}" || true
    fi

    exit "${exit_code}"
}

trap 'on_error "$?"' ERR

# =============================================================================
# ARGUMENTOS
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                export DRY_RUN
                shift
                ;;
            *)
                log_error "Argumento no soportado: $1"
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# VALIDACIONES LOCALES
# =============================================================================
require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || {
            log_error "Comando requerido no disponible: ${cmd}"
            exit 1
        }
    done
}

require_env_vars_local() {
    local var_name
    for var_name in "$@"; do
        if [[ -z "${!var_name:-}" ]]; then
            log_error "Variable requerida vacía o no definida: ${var_name}"
            exit 1
        fi
    done
}

# =============================================================================
# GESTIÓN DE IDENTIDADES
#
# Las funciones ensure_* usan execute_cmd (de utils.sh) directamente para que:
#   - Los comandos se registren en LOG_FILE.
#   - El drenaje de pipes en dry-run funcione correctamente.
#   - El comportamiento de dry-run sea consistente con el resto del framework.
# =============================================================================
ensure_group_exists() {
    local group_name="$1"

    if getent group "${group_name}" >/dev/null 2>&1; then
        log_info "Grupo '${group_name}' ya existe."
    else
        execute_cmd "groupadd --system '${group_name}'" "Creando grupo: ${group_name}"
    fi
}

ensure_user_exists() {
    local user_name="$1"
    local group_name="$2"

    if id -u "${user_name}" >/dev/null 2>&1; then
        log_info "Usuario '${user_name}' ya existe."
    else
        execute_cmd \
            "useradd --system --gid '${group_name}' --shell /usr/sbin/nologin --no-create-home '${user_name}'" \
            "Creando usuario de sistema: ${user_name}"
    fi
}

# Usa 'install -d' en lugar de mkdir+chown+chmod en tres pasos separados.
# 'install -d' es atómico, idempotente y aplica propietario, grupo y modo de una vez.
# Modo por defecto 2775: setgid activo para que los archivos nuevos hereden el
# grupo 'media' — vital para la interoperabilidad del stack *Arr.
ensure_directory() {
    local dir_path="$1"
    local owner="$2"
    local group="$3"
    local mode="${4:-2775}"

    execute_cmd \
        "install -d -o '${owner}' -g '${group}' -m '${mode}' '${dir_path}'" \
        "Asegurando directorio: ${dir_path} (${owner}:${group} ${mode})"
}

# =============================================================================
# GESTIÓN DE FSTAB
#
# Estrategia: generamos un candidato en un directorio temporal, lo comparamos
# con el fstab actual, y solo tocamos el disco si hay diferencias.
# El bloque gestionado se delimita con marcadores para permitir actualizaciones
# idempotentes sin duplicar entradas en ejecuciones sucesivas.
# =============================================================================
render_managed_fstab_block() {
    local output_file="$1"

    {
        echo "${FSTAB_BEGIN_MARKER}"
        jq -r '
            .puntos_de_montaje[]
            | "UUID=\(.uuid) \(.ruta) \(.fstype) \(.opciones) 0 2"
        ' "${MOUNTS_CONFIG}"
        echo "${FSTAB_END_MARKER}"
    } > "${output_file}"
}

# Extrae el fstab actual eliminando el bloque gestionado previo (si existe),
# y añade el nuevo bloque al final.
merge_managed_block_into_fstab() {
    local current_fstab="$1"
    local managed_block="$2"
    local output_fstab="$3"

    awk \
        -v begin="${FSTAB_BEGIN_MARKER}" \
        -v end="${FSTAB_END_MARKER}" \
        '
            $0 == begin { skip=1; next }
            $0 == end   { skip=0; next }
            !skip        { print }
        ' "${current_fstab}" > "${output_fstab}"

    printf '\n' >> "${output_fstab}"
    cat "${managed_block}" >> "${output_fstab}"
    printf '\n' >> "${output_fstab}"
}

validate_fstab_candidate() {
    local candidate_fstab="$1"

    # En dry-run, los UUIDs del candidato no existen en el sistema donde se
    # simula (ej: un PC de desarrollo en lugar de la RPi real), así que
    # findmnt reportaría errores falsos. Omitimos la validación.
    # En producción (sobre la RPi con los discos conectados) esto sí se ejecuta.
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "[DRY-RUN] Validación de fstab omitida (los UUIDs solo existen en la RPi real)."
        return 0
    fi

    if command -v findmnt >/dev/null 2>&1; then
        findmnt --verify --tab-file "${candidate_fstab}" >/dev/null
    else
        log_warning "findmnt no disponible; se omite validación estructural de fstab."
    fi
}

install_fstab_if_changed() {
    local candidate_fstab="$1"

    if cmp -s "${candidate_fstab}" "${FSTAB_FILE}" 2>/dev/null; then
        log_info "fstab ya está en el estado deseado. Sin cambios."
        return 0
    fi

    # Backup antes de cualquier escritura. FSTAB_BACKUP es también usada por
    # on_error para restaurar en caso de fallo posterior al backup.
    if [[ -f "${FSTAB_FILE}" && "${DRY_RUN}" != "true" ]]; then
        FSTAB_BACKUP="${FSTAB_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        log_info "Backup de fstab: ${FSTAB_BACKUP}"
        cp -a "${FSTAB_FILE}" "${FSTAB_BACKUP}"
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Reemplazaría ${FSTAB_FILE} con el bloque gestionado por Confiraspa."
        return 0
    fi

    install -o root -g root -m 0644 "${candidate_fstab}" "${FSTAB_FILE}"
    log_success "fstab actualizado."
}

# =============================================================================
# PUNTOS DE MONTAJE Y ACTIVACIÓN
#
# Process substitution en lugar de pipe: las modificaciones de variables dentro
# del loop no se pierden en un subshell.
# =============================================================================
create_mount_points_from_config() {
    while IFS= read -r mount_path; do
        ensure_directory "${mount_path}" root root 0755
    done < <(jq -r '.puntos_de_montaje[].ruta' "${MOUNTS_CONFIG}")
}

apply_mounts() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Omitiendo daemon-reload y mount -a."
        return 0
    fi

    # daemon-reload regenera las unidades .mount de systemd desde el fstab actualizado.
    systemctl daemon-reload

    # Con 'nofail' en las opciones de mounts.json, mount -a no falla si un disco
    # externo no está conectado, pero puede emitir warnings. Los registramos sin abortar.
    mount -a || log_warning "mount -a reportó advertencias (puede ser normal si algún disco externo no está conectado)."
}

# =============================================================================
# ESTRUCTURA DE DIRECTORIOS MULTIMEDIA
# =============================================================================
ensure_media_layout() {
    local media_owner="${ARR_USER}"
    local media_group="${ARR_GROUP}"

    log_info "Configurando identidad del stack multimedia: ${media_owner}:${media_group}"
    ensure_group_exists "${media_group}"
    ensure_user_exists  "${media_owner}" "${media_group}"

    log_info "Creando estructura de directorios multimedia..."
    ensure_directory "${PATH_LIBRARY}"   "${media_owner}" "${media_group}" 2775
    ensure_directory "${PATH_DOWNLOADS}" "${media_owner}" "${media_group}" 2775
    ensure_directory "${PATH_BACKUP}"    "${media_owner}" "${media_group}" 2775

    ensure_directory "${DIR_SERIES}"   "${media_owner}" "${media_group}" 2775
    ensure_directory "${DIR_MOVIES}"   "${media_owner}" "${media_group}" 2775
    ensure_directory "${DIR_MUSIC}"    "${media_owner}" "${media_group}" 2775
    ensure_directory "${DIR_BOOKS}"    "${media_owner}" "${media_group}" 2775
    ensure_directory "${DIR_TORRENTS}" "${media_owner}" "${media_group}" 2775
}

# =============================================================================
# POST-CHECKS
# =============================================================================
post_checks() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Omitiendo post-checks de montaje."
        return 0
    fi

    while IFS= read -r mount_path; do
        if mountpoint -q "${mount_path}"; then
            log_success "Montaje activo: ${mount_path}"
        else
            log_warning "Ruta existe pero no está montada como mountpoint: ${mount_path}"
        fi
    done < <(jq -r '.puntos_de_montaje[].ruta' "${MOUNTS_CONFIG}")
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    # FIX: temp_dir es local a main, inicializada vacía antes del trap.
    # El trap usa ${temp_dir:-} con operador de default vacío para que set -u
    # no falle si el EXIT se dispara antes de que mktemp asigne la variable
    # (ej: fallo en parse_args o validate_root).
    local temp_dir managed_block candidate_fstab
    temp_dir=""

    # shellcheck disable=SC2064
    # SC2064: queremos expansión en tiempo de definición del trap para capturar
    # el valor de temp_dir en el momento de la asignación.
    # Usamos ${temp_dir:-} para proteger el caso en que temp_dir esté vacía.
    trap 'rm -rf "${temp_dir:-}"' EXIT

    parse_args "$@"
    validate_root
    require_commands jq awk install cp mount mountpoint
    require_env_vars_local \
        ARR_USER ARR_GROUP \
        PATH_LIBRARY PATH_DOWNLOADS PATH_BACKUP \
        DIR_SERIES DIR_MOVIES DIR_MUSIC DIR_BOOKS DIR_TORRENTS

    [[ -f "${MOUNTS_CONFIG}" ]] || {
        log_error "No existe el archivo de configuración: ${MOUNTS_CONFIG}"
        exit 1
    }

    log_section "Configuración de almacenamiento y permisos"

    temp_dir="$(mktemp -d)"
    managed_block="${temp_dir}/managed_fstab.block"
    candidate_fstab="${temp_dir}/fstab.candidate"

    # Pipeline de actualización de fstab:
    # 1. Crear puntos de montaje físicos desde el JSON
    # 2. Renderizar el bloque nuevo
    # 3. Fusionarlo con el fstab existente (elimina bloque anterior si existe)
    # 4. Validar sintaxis del candidato (omitido en dry-run)
    # 5. Instalar solo si hay cambios reales
    create_mount_points_from_config
    render_managed_fstab_block "${managed_block}"
    merge_managed_block_into_fstab "${FSTAB_FILE}" "${managed_block}" "${candidate_fstab}"
    validate_fstab_candidate "${candidate_fstab}"
    install_fstab_if_changed "${candidate_fstab}"

    apply_mounts
    ensure_media_layout
    post_checks

    log_success "Almacenamiento y estructura de directorios configurados correctamente."
}

main "$@"