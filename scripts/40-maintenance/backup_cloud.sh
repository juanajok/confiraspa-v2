#!/usr/bin/env bash
# scripts/40-maintenance/backup_cloud.sh
# Motor de backup Cloud → Local vía rclone con integridad y protección de disco.
#
# Lee cloud_backups.json para obtener los jobs (nombre, origen remoto,
# destino local, modo). Ejecuta rclone con verificación por checksum.
#
# FIX CRÍTICO (v9): rclone se ejecuta con --config apuntando a la config
# del usuario SYS_USER (pi), no de root. Esto resuelve el error:
#   "didn't find section in config file" que aparecía cuando cron
#   ejecutaba el script como root y rclone caía al default /root/.config/.
#
# PROTECCIONES:
#   - Validación previa: comprueba que rclone.conf existe y que todos los
#     remotes referenciados en el JSON están configurados.
#   - Safety sync: aborta si BACKUP_ROOT está vacío (posible disco desmontado).
#   - Timeout por job: protege contra cuelgues indefinidos (default 6h).
#   - Throttling horario: sin límite de noche (01-07h), 20M/s de día.
#   - fast-list condicional: solo si hay >1GB de RAM disponible.
#
# Diseñado para ejecutarse desde cron (domingos 05:00 AM) con prioridad baja.

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

# Cargar .env (una sola vez)
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# LOG_FILE para ejecución desde cron
if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="/var/log/rclone_backup.log"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly CONFIG_JSON="${REPO_ROOT}/configs/static/cloud_backups.json"
readonly LOCK_FILE="/run/lock/confiraspa_rclone.lock"

# Usuario propietario de la configuración de rclone (normalmente 'pi')
readonly RCLONE_USER="${SYS_USER:-pi}"
readonly RCLONE_CONFIG="/home/${RCLONE_USER}/.config/rclone/rclone.conf"
readonly RCLONE_DETAIL_LOG="/var/log/rclone_detail.log"

# Umbral mínimo de espacio libre por job (2GB)
readonly MIN_DISK_SPACE_MB=2048

# Configuración de throttling (horas en formato 24h, sin ceros a la izquierda)
readonly BW_NIGHT_START="${RCLONE_BW_NIGHT_START:-1}"   # 01:00 AM
readonly BW_NIGHT_END="${RCLONE_BW_NIGHT_END:-7}"       # 07:00 AM
readonly BW_DAY_LIMIT="${RCLONE_BW_DAY_LIMIT:-20M}"

# Timeout por job (evita cuelgues; subir si hay primera sincronización grande)
readonly JOB_TIMEOUT="${RCLONE_JOB_TIMEOUT:-6h}"

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
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN="true" ;;
            *) log_warning "Argumento desconocido: $1" ;;
        esac
        shift
    done
    export DRY_RUN
}

# renice/ionice son operaciones de proceso, no de filesystem.
# Se ejecutan directamente porque deben aplicarse incluso en dry-run.
lower_priority() {
    renice -n 19 $$ > /dev/null 2>&1 || true   # Fallo aceptable en cgroups restringidos
    ionice -c3 -p $$ > /dev/null 2>&1 || true  # Fallo aceptable en kernels sin CFQ
}

# --- Throttling dinámico según hora ---
# De noche (01-07h): sin límite de banda. De día: limitado para no saturar red.
get_dynamic_bwlimit() {
    local hour
    hour=$(date +%-H)  # %-H: sin ceros a la izquierda (POSIX: 0-23)

    if [[ "${hour}" -ge "${BW_NIGHT_START}" && "${hour}" -lt "${BW_NIGHT_END}" ]]; then
        echo "0"  # Sin límite
    else
        echo "${BW_DAY_LIMIT}"
    fi
}

# --- Check de RAM disponible (para decidir --fast-list) ---
# fast-list carga toda la estructura remota en memoria, acelerando operaciones
# pero consumiendo hasta 1GB en bibliotecas grandes. Solo activar si hay margen.
has_sufficient_ram() {
    local available_mb
    available_mb=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
    [[ "${available_mb:-0}" -gt 1024 ]]
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

validate_env_vars() {
    validate_var "SYS_USER" "${SYS_USER:-}"
    validate_var "ARR_GROUP" "${ARR_GROUP:-}"
    validate_var "PATH_BACKUP" "${PATH_BACKUP:-}"
}

# --- Validar que rclone.conf existe y contiene todos los remotes del JSON ---
# Esta validación previa evita que 9 jobs fallen en cascada cuando el
# problema es simplemente que un remote no está configurado.
validate_rclone_config() {
    if [[ ! -f "${RCLONE_CONFIG}" ]]; then
        log_error "rclone.conf no encontrado en ${RCLONE_CONFIG}"
        log_error "Configúralo como usuario '${RCLONE_USER}': rclone config"
        return 1
    fi

    # Extraer remotes únicos del JSON (parte antes del ':' en cada origen)
    local -a needed_remotes
    mapfile -t needed_remotes < <(jq -r '.jobs[].origen' "${CONFIG_JSON}" \
        | awk -F: '{print $1}' | sort -u)

    if [[ ${#needed_remotes[@]} -eq 0 ]]; then
        log_warning "No hay remotes definidos en ${CONFIG_JSON}"
        return 0
    fi

    # Verificar cada remote contra las secciones de rclone.conf
    local remote
    local -a missing_remotes=()
    for remote in "${needed_remotes[@]}"; do
        if ! grep -qE "^\[${remote}\][[:space:]]*$" "${RCLONE_CONFIG}"; then
            missing_remotes+=("${remote}")
        fi
    done

    if [[ ${#missing_remotes[@]} -gt 0 ]]; then
        log_error "Faltan ${#missing_remotes[@]} remote(s) en ${RCLONE_CONFIG}:"
        local r
        for r in "${missing_remotes[@]}"; do
            log_error "  - ${r}"
        done
        log_error "Configúralos como usuario '${RCLONE_USER}': rclone config"
        return 1
    fi

    log_success "Remotes verificados: ${#needed_remotes[@]} configurados correctamente."
    return 0
}

# --- Comprobar que el disco de backup está montado y no vacío ---
validate_backup_disk() {
    if [[ ! -d "${PATH_BACKUP}" ]]; then
        log_error "Directorio de backup no existe: ${PATH_BACKUP}"
        exit 1
    fi

    if [[ -z "$(find "${PATH_BACKUP}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        log_error "CRÍTICO: ${PATH_BACKUP} está vacío. Posible disco desmontado."
        log_error "Abortando para prevenir escritura en la SD."
        exit 1
    fi
}

# --- Ejecutar un job de rclone ---
# RISK: timeout con --kill-after envía SIGKILL a rclone si supera JOB_TIMEOUT.
# Puede dejar ficheros parcialmente transferidos en destino.
# Mitigación: rclone es idempotente — la siguiente ejecución completa el job.
run_cloud_job() {
    local name="$1"
    local src="$2"
    local dest="$3"
    local mode="$4"

    log_subsection "Job: ${name}"
    log_info "Modo:    ${mode}"
    log_info "Origen:  ${src}"
    log_info "Destino: ${dest}"

    # Check de espacio antes de empezar
    local check_dir="${dest}"
    [[ -d "${dest}" ]] || check_dir="$(dirname "${dest}")"

    if ! check_disk_space "${check_dir}" "${MIN_DISK_SPACE_MB}"; then
        log_error "Espacio insuficiente (<${MIN_DISK_SPACE_MB}MB) en ${check_dir}. Saltando '${name}'."
        return 1
    fi

    # Crear destino si no existe (con permisos de grupo media)
    if [[ ! -d "${dest}" ]]; then
        execute_cmd "install -d -o '${RCLONE_USER}' -g '${ARR_GROUP}' -m 775 '${dest}'" \
            "Creando directorio destino: ${dest}"
    fi

    # Modo destructivo: avisar
    if [[ "${mode}" == "sync" ]]; then
        log_warning "Modo 'sync': los archivos borrados en origen se borrarán también en destino."
    fi

    # Throttling dinámico
    local bw_limit
    bw_limit=$(get_dynamic_bwlimit)
    local bw_display="${bw_limit}"
    [[ "${bw_limit}" == "0" ]] && bw_display="sin límite"

    # Construir flags
    local -a rclone_flags=(
        "--config=${RCLONE_CONFIG}"
        "--transfers=4"
        "--checkers=8"
        "--bwlimit=${bw_limit}"
        "--retries=3"
        "--low-level-retries=10"
        "--contimeout=20s"        # Timeout de handshake (evita cuelgues iniciales)
        "--timeout=5m"            # Timeout de inactividad de transferencia
        "--stats=1m"
        "--stats-one-line"
        "--log-file=${RCLONE_DETAIL_LOG}"
        "--log-level=INFO"
        "--checksum"              # Integridad por hash, no solo tamaño/fecha
        "--create-empty-src-dirs"
        "--user-agent=ConfiraspaBackup/1.0"
    )

    # Flags específicos de Google Drive
    if [[ "${src,,}" =~ gdrive ]]; then
        rclone_flags+=("--drive-skip-gdocs")

        if has_sufficient_ram; then
            rclone_flags+=("--fast-list")
            log_info "fast-list activado (>1GB RAM disponible)"
        else
            log_info "fast-list omitido (RAM insuficiente)"
        fi
    fi

    # Modo sync: borrar solo al final, no durante (más seguro)
    if [[ "${mode}" == "sync" ]]; then
        rclone_flags+=("--delete-after")
    fi

    # Dry-run de rclone (además del dry-run de execute_cmd)
    if [[ "${DRY_RUN}" == "true" ]]; then
        rclone_flags+=("--dry-run")
    fi

    log_info "Transfiriendo (banda: ${bw_display}, timeout: ${JOB_TIMEOUT})..."

    # Construir comando completo como string para execute_cmd.
    # TRADE-OFF: usamos printf %q para quotear cada flag de forma segura,
    # en lugar de bypassear execute_cmd. Es más verboso pero respeta el
    # framework de dry-run y logging del proyecto.
    # sudo -u ${RCLONE_USER}: rclone corre como 'pi' para que el token cache
    # de OAuth se escriba en el home de pi (no de root).
    local cmd_str="timeout --kill-after=30s ${JOB_TIMEOUT} sudo -u ${RCLONE_USER} rclone ${mode}"
    local flag
    for flag in "${rclone_flags[@]}"; do
        cmd_str+=" $(printf '%q' "${flag}")"
    done
    cmd_str+=" $(printf '%q' "${src}") $(printf '%q' "${dest}")"

    if execute_cmd "${cmd_str}" "Rclone: ${name}"; then
        log_success "Job '${name}' completado."

        # Métrica post-job (solo si el directorio existe)
        if [[ -d "${dest}" && "${DRY_RUN}" != "true" ]]; then
            local usage
            usage=$(df -h "${dest}" | awk 'NR==2 {printf "%s usado / %s libre (%s)", $3, $4, $5}')
            log_info "  Espacio: ${usage}"
        fi
        return 0
    else
        local rc=$?
        if [[ "${rc}" -eq 124 ]]; then
            log_error "Job '${name}' ABORTADO por timeout de ${JOB_TIMEOUT}."
        else
            log_error "Fallo en job '${name}' (código ${rc}). Detalles en ${RCLONE_DETAIL_LOG}"
        fi
        return 1
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Sincronización Cloud → Local (Rclone)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands rclone jq find df timeout sudo awk
    validate_env_vars

    if [[ ! -f "${CONFIG_JSON}" ]]; then
        log_error "Configuración no encontrada: ${CONFIG_JSON}"
        exit 1
    fi

    # Validación previa de remotes — falla rápido y claro si falta alguno
    if ! validate_rclone_config; then
        exit 1
    fi

    # --- 2. Lock y prioridad baja ---
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        log_error "Un proceso de backup cloud ya está en ejecución (lock: ${LOCK_FILE})."
        exit 1
    fi

    lower_priority

    # --- 3. Safety check: disco de backup montado ---
    validate_backup_disk

    # --- 4. Leer jobs del JSON ---
    # mapfile con 4 campos por job: name, origen, destino, mode
    local -a all_fields
    mapfile -t all_fields < <(jq -r '.jobs[] | .name, .origen, .destino, (.mode // "sync")' "${CONFIG_JSON}")

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
            (( job_count++ )) || true  # (( )) retorna 1 cuando resultado es 0
        else
            (( fail_count++ )) || true  # Idem
        fi
    done

    # --- 6. Resumen ---
    log_section "Resumen"
    log_info "  Jobs completados: ${job_count}"
    if [[ "${fail_count}" -gt 0 ]]; then
        log_warning "  Jobs con fallos: ${fail_count}"
        log_info "  Detalles técnicos: ${RCLONE_DETAIL_LOG}"
        exit 1
    fi

    log_success "Ciclo de backups cloud finalizado con éxito."
}

main "$@"