#!/usr/bin/env bash
# scripts/40-maintenance/backup_cloud.sh
# Motor de backup Cloud→Local vía rclone con integridad y protección de disco.
#
# Lee cloud_backups.json para obtener los jobs (nombre, origen remoto, destino local).
# Ejecuta rclone con --checksum para verificar integridad por hash, no solo tamaño/fecha.
#
# PROTECCIÓN CRÍTICA: Si el directorio de backup raíz (PATH_BACKUP) existe pero está
# vacío, el disco puede estar desmontado (nofail en fstab). En ese caso se aborta
# para evitar que rclone escriba en la SD llenándola.
#
# Diseñado para ejecutarse desde cron (domingos 05:00 AM) con prioridad baja.

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
readonly CONFIG_FILE="${REPO_ROOT}/configs/static/cloud_backups.json"
readonly LOCK_FILE="/run/lock/confiraspa_rclone.lock"
readonly RCLONE_LOG="/var/log/rclone_backup.log"

# Ruta raíz de backups — del .env, no hardcodeada
readonly BACKUP_ROOT="${PATH_BACKUP:-/media/Backup}"

# Flags de rclone como array (seguro, sin problemas de word-splitting)
readonly RCLONE_BASE_FLAGS=(
    -v
    --transfers 4
    --create-empty-src-dirs
    --drive-skip-gdocs
    --stats-one-line
    --user-agent "ConfiraspaBackup/1.0"
    --checksum       # Integridad por hash, no solo tamaño/fecha
    --timeout 10m    # Evita cuelgues infinitos en conexiones rotas
)

# Umbral mínimo de espacio libre en MB para continuar (2GB)
readonly MIN_DISK_SPACE_MB=2048

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
        log_error "Un proceso de backup cloud ya está en ejecución (lock: ${LOCK_FILE})."
        exit 1
    fi
}

# --- Reducir prioridad para no degradar servicios multimedia ---
lower_priority() {
    renice -n 19 $$ > /dev/null 2>&1 || true
    ionice -c3 -p $$ > /dev/null 2>&1 || true
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Comprobar que el disco de backup está montado y no vacío ---
validate_backup_disk() {
    if [[ ! -d "${BACKUP_ROOT}" ]]; then
        log_error "Directorio de backup no existe: ${BACKUP_ROOT}"
        exit 1
    fi

    if [[ -z "$(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        log_error "CRÍTICO: ${BACKUP_ROOT} está vacío. Posible disco desmontado."
        log_error "Abortando para prevenir escritura en la SD."
        exit 1
    fi
}

# --- Comprobar espacio libre en disco ---
# Retorna 0 si hay al menos $MIN_DISK_SPACE_MB disponibles, 1 si no.
check_disk_space() {
    local path="$1"

    # df -PM: POSIX output, en MB. Columna 4 = Available.
    local avail_mb
    avail_mb=$(df -PM "${path}" 2>/dev/null | awk 'NR==2 {print $4}') || return 1

    if [[ "${avail_mb}" -lt "${MIN_DISK_SPACE_MB}" ]]; then
        return 1
    fi

    return 0
}

# --- Ejecutar un job de rclone ---
run_cloud_job() {
    local name="$1"
    local src="$2"
    local dest="$3"
    local mode="$4"

    log_subsection "Job: ${name}"
    log_info "Modo:    ${mode}"
    log_info "Origen:  ${src}"
    log_info "Destino: ${dest}"

    # Check de espacio en disco antes de empezar
    local check_dir="${dest}"
    [[ -d "${dest}" ]] || check_dir="$(dirname "${dest}")"

    if ! check_disk_space "${check_dir}"; then
        log_error "Espacio insuficiente (<${MIN_DISK_SPACE_MB}MB) en ${check_dir}. Saltando '${name}'."
        return 1
    fi

    # Crear destino si no existe
    if [[ ! -d "${dest}" ]]; then
        execute_cmd "install -d -o '${ARR_USER:-media}' -g '${ARR_GROUP:-media}' -m 775 '${dest}'" \
            "Creando directorio destino: ${dest}"
    fi

    # Advertencia para modo sync
    if [[ "${mode}" == "sync" ]]; then
        log_warning "Modo 'sync': archivos borrados en nube se borrarán en local."
    fi

    # Construir comando como array (seguro, soporta rutas con espacios)
    local -a cmd=("rclone" "${mode}")
    cmd+=("${RCLONE_BASE_FLAGS[@]}")

    # Dry-run a nivel de rclone: muestra qué haría sin ejecutar
    if [[ "${DRY_RUN}" == "true" ]]; then
        cmd+=("--dry-run")
        log_warning "[DRY-RUN] Simulación activa en rclone."
    fi

    cmd+=("${src}" "${dest}")

    # Ejecutar — umask scoped solo a este comando
    log_info "Ejecutando transferencia con verificación de integridad..."
    if (umask 002 && "${cmd[@]}" >> "${RCLONE_LOG}" 2>&1); then
        log_success "Job '${name}' completado."
        return 0
    else
        log_error "Fallo en job '${name}'. Detalles en ${RCLONE_LOG}"
        return 1
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Sincronización Cloud → Local (Rclone)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands rclone jq find df

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "Configuración no encontrada: ${CONFIG_FILE}"
        exit 1
    fi

    # --- 2. Lock y prioridad baja ---
    acquire_lock
    lower_priority

    # --- 3. Safety check: disco de backup montado ---
    validate_backup_disk

    # --- 4. Leer jobs del JSON ---
    # mapfile con 4 campos por job: name, origen, destino, mode
    local -a all_fields
    mapfile -t all_fields < <(jq -r '.jobs[] | .name, .origen, .destino, (.mode // "sync")' "${CONFIG_FILE}")

    local total_fields=${#all_fields[@]}
    if [[ "${total_fields}" -eq 0 ]]; then
        log_warning "No hay trabajos de backup cloud definidos en el JSON."
        return 0
    fi

    if (( total_fields % 4 != 0 )); then
        log_error "JSON inconsistente (${total_fields} campos, se esperan múltiplos de 4)."
        exit 1
    fi

    # --- 5. Procesar cada job ---
    local i name src dest mode
    local job_count=0
    local fail_count=0

    for (( i=0; i<total_fields; i+=4 )); do
        name="${all_fields[i]:-}"
        src="${all_fields[i+1]:-}"
        dest="${all_fields[i+2]:-}"
        mode="${all_fields[i+3]:-sync}"

        if [[ -z "${name}" || -z "${src}" || -z "${dest}" ]]; then
            log_warning "Job con campos vacíos (posición $((i/4+1))). Saltando."
            continue
        fi

        if run_cloud_job "${name}" "${src}" "${dest}" "${mode}"; then
            (( job_count++ )) || true
        else
            (( fail_count++ )) || true
        fi
    done

    # --- 6. Resumen ---
    log_success "Ciclo de backups cloud finalizado."
    log_info "  Jobs completados: ${job_count}"
    if [[ "${fail_count}" -gt 0 ]]; then
        log_warning "  Jobs con fallos: ${fail_count}"
    fi
}

main "$@"