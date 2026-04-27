#!/usr/bin/env bash
# scripts/40-maintenance/backup_rsync.sh
# Motor de copias de seguridad incremental con protecciones de seguridad.
#
# Lee backup_rsync.json para obtener los jobs de backup (nombre, origen, destino).
# Ejecuta rsync con --delete para mantener el destino sincronizado con el origen.
#
# PROTECCIÓN CRÍTICA: Si el directorio origen está vacío (posible disco desmontado
# con nofail en fstab), el job se salta para evitar que --delete borre todo el
# backup. Esta protección salva de perder datos cuando un USB se desconecta.
#
# Diseñado para ejecutarse desde cron (diariamente a las 04:00) con prioridad
# baja para no degradar los servicios multimedia en la RPi.

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

# Cargar .env si no estamos bajo install.sh
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# LOG_FILE para ejecución desde cron
if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="/var/log/backup_rsync.log"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly CONFIG_FILE="${REPO_ROOT}/configs/static/backup_rsync.json"
readonly LOCK_FILE="/run/lock/confiraspa_rsync_backup.lock"

# Opciones de rsync:
#   -a: archive (preserva permisos, dueños, fechas, symlinks)
#   -v: verbose (para el log)
#   -h: human-readable sizes
#   --delete: borra en destino lo que no existe en origen (PELIGROSO si falla montaje)
readonly RSYNC_BASE_OPTS="-avh --delete"

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

# --- Adquirir lock exclusivo ---
acquire_lock() {
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        log_error "Un proceso de backup rsync ya está en ejecución (lock: ${LOCK_FILE})."
        exit 1
    fi
}

# --- Reducir prioridad para no degradar servicios multimedia ---
# renice/ionice: operaciones de proceso, no de filesystem.
# Deben aplicarse incluso en dry-run. || true justificado abajo.
lower_priority() {
    renice -n 19 $$ > /dev/null 2>&1 || true  # Fallo aceptable en cgroups restringidos
    ionice -c3 -p $$ > /dev/null 2>&1 || true  # Fallo aceptable en kernels sin CFQ
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Comprobar que el origen no está vacío (protección disco desmontado) ---
# Con nofail en fstab, si un disco USB se desconecta el punto de montaje
# existe pero está vacío. rsync --delete sincronizaría esa nada con el
# destino, borrando todo el backup. Este check lo previene.
is_source_safe() {
    local src="$1"

    if [[ ! -e "${src}" ]]; then
        log_error "El origen no existe: ${src}. Saltando para proteger el destino."
        return 1
    fi

    if [[ -d "${src}" ]]; then
        if [[ -z $(find "${src}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
            log_warning "El directorio origen está VACÍO: ${src}"
            log_warning "Posible disco desmontado. Abortando este job para proteger el backup."
            return 1
        fi
    fi

    return 0
}

# --- Ejecutar un job de rsync ---
run_backup_job() {
    local name="$1"
    local src="$2"
    local dest="$3"
    local exclude_raw="${4:-}"

    log_subsection "Backup: ${name}"
    log_info "Origen:  ${src}"
    log_info "Destino: ${dest}"

    # Safety check: origen existe y no está vacío
    if ! is_source_safe "${src}"; then
        return 0  # Continuamos con el siguiente job sin abortar el script
    fi

    # Crear destino si no existe
    if [[ ! -d "${dest}" ]]; then
        execute_cmd "mkdir -p '${dest}'" \
            "Creando directorio destino: ${dest}"
    fi

    # Construir flags de exclusión a partir de patrones separados por '|'
    local exclude_flags=""
    if [[ -n "${exclude_raw}" ]]; then
        local pattern
        while IFS= read -r pattern; do
            exclude_flags+=" --exclude='${pattern}'"
        done < <(echo "${exclude_raw}" | tr '|' '\n')
        log_info "Exclusiones: ${exclude_raw//|/, }"
    fi

    # Construir comando rsync como string para execute_cmd.
    # ${src%/}/ asegura barra final → rsync copia el CONTENIDO, no la carpeta.
    local rsync_cmd="rsync ${RSYNC_BASE_OPTS}${exclude_flags} '${src%/}/' '${dest%/}/'"

    log_info "Sincronizando..."
    if execute_cmd "${rsync_cmd}" "Rsync: ${name}"; then
        log_success "Backup '${name}' completado."
    else
        log_error "Fallo en backup '${name}'. Verifica permisos o espacio en disco."
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Ejecución de Copias de Seguridad (Rsync)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands rsync jq find

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "No se encuentra el archivo de definición de backups: ${CONFIG_FILE}"
        exit 1
    fi

    # --- 2. Lock y prioridad baja ---
    acquire_lock
    lower_priority

    # --- 3. Leer jobs del JSON ---
    # Usamos mapfile por línea (una línea por campo) en lugar de @tsv,
    # para evitar el colapso de campos vacíos que encontramos en restore_apps.
    # Cada job emite 4 líneas: name, origen, destino, exclude (vacío si no definido).
    local -a all_fields
    mapfile -t all_fields < <(jq -r '.jobs[] | .name, .origen, .destino, (.exclude // [] | join("|"))' "${CONFIG_FILE}")

    local total_fields=${#all_fields[@]}
    if [[ "${total_fields}" -eq 0 ]]; then
        log_warning "No hay trabajos de backup definidos en el JSON."
        return 0
    fi

    # Verificar que el número de campos es múltiplo de 4
    if (( total_fields % 4 != 0 )); then
        log_error "El JSON tiene campos inconsistentes (${total_fields} valores, se esperan múltiplos de 4)."
        exit 1
    fi

    # --- 4. Procesar cada job ---
    local i name src dest exclude_raw
    local job_count=0
    local fail_count=0

    for (( i=0; i<total_fields; i+=4 )); do
        name="${all_fields[i]:-}"
        src="${all_fields[i+1]:-}"
        dest="${all_fields[i+2]:-}"
        exclude_raw="${all_fields[i+3]:-}"

        # Validación defensiva
        if [[ -z "${name}" || -z "${src}" || -z "${dest}" ]]; then
            log_warning "Job con campos vacíos (posición $((i/4+1))). Saltando."
            continue
        fi

        if run_backup_job "${name}" "${src}" "${dest}" "${exclude_raw}"; then
            (( job_count++ )) || true  # (( )) retorna 1 cuando resultado es 0
        else
            (( fail_count++ )) || true  # Idem
        fi
    done

    # --- 5. Resumen ---
    log_success "Proceso de copias de seguridad finalizado."
    log_info "  Jobs completados: ${job_count}"
    if [[ "${fail_count}" -gt 0 ]]; then
        log_warning "  Jobs con fallos: ${fail_count}"
    fi
}

main "$@"