#!/usr/bin/env bash
# install.sh
# Orquestador principal de Confiraspa
#
# Uso:
#   sudo ./install.sh
#   sudo ./install.sh --dry-run
#   sudo ./install.sh --only samba
#   sudo ./install.sh --only scripts/30-services/samba.sh
#   sudo ./install.sh --help

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOCK_FILE="/run/lock/confiraspa_install.lock"

# Variables globales de estado (modificadas por run_stage y setup_environment)
DRY_RUN=false
ONLY_FILTER=""
LOG_FILE=""
EXECUTED_COUNT=0

# =============================================================================
# CARGA DE LIBRERÍAS
# =============================================================================
source "${REPO_ROOT}/lib/colors.sh"
source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

# =============================================================================
# MANEJO DE ERRORES
#
# FIX: Usamos BASH_LINENO[0] dentro del handler en lugar de pasar ${LINENO}
# como argumento del trap. ${LINENO} en el trap apunta a la línea del propio
# trap, no al origen del error. BASH_LINENO[0] contiene la línea real.
# =============================================================================
on_error() {
    local exit_code="${1:-1}"
    # BASH_LINENO[0] = línea donde ocurrió el error
    # BASH_LINENO[1] = línea del caller de esa función (si aplica)
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Fallo inesperado en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."
    [[ -n "${LOG_FILE:-}" ]] && log_error "Consulta el log: ${LOG_FILE}"
    exit "${exit_code}"
}

# Solo pasamos el exit code; la línea se lee desde BASH_LINENO dentro del handler.
trap 'on_error "$?"' ERR

# =============================================================================
# AYUDA / USO
# =============================================================================
usage() {
    cat <<'EOF'
Uso:
  sudo ./install.sh [--dry-run] [--only <script|ruta_relativa>] [--help]

Opciones:
  --dry-run             Simula la ejecución sin aplicar cambios reales.
  --only <valor>        Ejecuta solo un script concreto.
                        Acepta:
                          - basename sin .sh   (ej. samba)
                          - ruta relativa      (ej. scripts/30-services/samba.sh)
  --help                Muestra esta ayuda.

Ejemplos:
  sudo ./install.sh
  sudo ./install.sh --dry-run
  sudo ./install.sh --only samba
  sudo ./install.sh --only scripts/00-system/20-storage.sh
EOF
}

# =============================================================================
# ARGUMENTOS
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --only)
                [[ $# -lt 2 ]] && {
                    echo "ERROR: --only requiere un valor." >&2
                    usage
                    exit 1
                }
                ONLY_FILTER="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "ERROR: argumento desconocido: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# ENTORNO / LOCK / LOG
#
# FIX: Separamos las tres responsabilidades en subfunciones privadas con orden
# explícito: permisos → lock → log → env. Si el lock falla, el log aún no
# se ha inicializado y el error se ve limpio en stderr. Si el .env falta,
# el log ya está activo y registra el problema correctamente.
# =============================================================================
_acquire_lock() {
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        log_error "Ya hay una ejecución activa de Confiraspa (lock: ${LOCK_FILE})."
        exit 1
    fi
}

_init_log() {
    LOG_FILE="${REPO_ROOT}/logs/install_$(date +%Y%m%d_%H%M%S).log"
    export LOG_FILE
    init_logging "${LOG_FILE}"
}

_load_env() {
    if [[ ! -f "${REPO_ROOT}/.env" ]]; then
        log_error "Falta ${REPO_ROOT}/.env. Copia .env.example y configúralo."
        exit 1
    fi
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
}

setup_environment() {
    export REPO_ROOT
    export DRY_RUN

    validate_root   # 1. Permisos — primero, antes de tocar nada
    _acquire_lock   # 2. Exclusión mutua — antes de abrir el log
    _init_log       # 3. Log — operativo para el resto del setup
    _load_env       # 4. Variables de usuario — último, ya tenemos log si falla
}

# =============================================================================
# METADATOS DEL PIPELINE
#
# Formato: "required|ruta_relativa" u "optional|ruta_relativa"
# - required: el instalador aborta si el script no existe.
# - optional: se omite con un warning si no existe.
# =============================================================================
declare -a STAGES=(
    # --- 00 SYSTEM ---
    "required|scripts/00-system/00-update.sh"
    "required|scripts/00-system/10-users.sh"
    "required|scripts/00-system/20-storage.sh"

    # --- 10 NETWORK ---
    "optional|scripts/10-network/00-static-ip.sh"
    "required|scripts/10-network/firewall.sh"
    "optional|scripts/10-network/10-xrdp.sh"
    "optional|scripts/10-network/20-vnc.sh"

    # --- 20 LIBS ---
   #"optional|lib/install_mono.sh"

    # --- 30 SERVICES (CORE) ---
    "optional|scripts/30-services/samba.sh"
    "optional|scripts/30-services/rclone.sh"
    "optional|scripts/30-services/rsync.sh"

    # --- 30 SERVICES (APPS) ---
    "optional|scripts/30-services/transmission.sh"
    "optional|scripts/30-services/arr_suite.sh"
    "optional|scripts/30-services/sonarr.sh"
    "optional|scripts/30-services/bazarr.sh"
    "optional|scripts/30-services/calibre.sh"
    "optional|scripts/30-services/plex.sh"
    "optional|scripts/30-services/amule.sh"
    "optional|scripts/30-services/webmin.sh"

    # --- 40 MAINTENANCE ---
    "optional|scripts/40-maintenance/configurar_swap_zswap.sh"
    "optional|scripts/40-maintenance/cron.sh"
    "optional|scripts/40-maintenance/logrotate.sh"
    "optional|scripts/40-maintenance/fix_permissions.sh"
)

# =============================================================================
# HELPERS
# =============================================================================

# Obtiene la IP de la interfaz de salida por defecto.
# Más fiable que 'hostname -I' porque no depende de /etc/hosts ni del orden
# de interfaces. Fallback a hostname -I y luego a 127.0.0.1.
get_host_ip() {
    local ip_addr=""
    ip_addr="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')"
    if [[ -z "${ip_addr}" ]]; then
        ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s\n' "${ip_addr:-127.0.0.1}"
}

# Devuelve 0 si la ruta relativa dada coincide con el filtro --only activo.
# Sin filtro activo, siempre devuelve 0 (ejecutar todo).
# Acepta tanto ruta relativa completa como basename sin extensión.
matches_only_filter() {
    local relative_path="$1"
    local basename_no_ext
    basename_no_ext="$(basename "${relative_path}" .sh)"

    [[ -z "${ONLY_FILTER}" ]] && return 0
    [[ "${ONLY_FILTER}" == "${relative_path}" ]] && return 0
    [[ "${ONLY_FILTER}" == "${basename_no_ext}" ]] && return 0

    return 1
}

# Verifica que al menos una etapa del pipeline coincide con el filtro --only.
# Previene que '--only typo' termine silenciosamente con exit 0.
stage_exists_for_filter() {
    local entry required_flag relative_path

    for entry in "${STAGES[@]}"; do
        IFS='|' read -r required_flag relative_path <<< "${entry}"
        if matches_only_filter "${relative_path}"; then
            return 0
        fi
    done

    return 1
}

# Ejecuta una etapa del pipeline.
# - Respeta el filtro --only.
# - Distingue entre scripts required y optional.
# - Pasa --dry-run como argumento explícito Y lo hereda vía export DRY_RUN.
#   Ambos mecanismos coexisten: el argumento permite ejecutar scripts
#   directamente desde la línea de comandos con el mismo comportamiento.
# - Usa 'bash script.sh' para no depender del bit ejecutable.
run_stage() {
    local required_flag="$1"
    local relative_path="$2"
    local full_path="${REPO_ROOT}/${relative_path}"
    local stage_name
    local -a script_args=()

    stage_name="$(basename "${relative_path}" .sh)"

    # Si hay filtro activo y esta etapa no coincide, la saltamos silenciosamente.
    if ! matches_only_filter "${relative_path}"; then
        return 0
    fi

    # Verificar existencia del script.
    if [[ ! -f "${full_path}" ]]; then
        if [[ "${required_flag}" == "required" ]]; then
            log_error "Falta script obligatorio: ${relative_path}"
            exit 1
        fi
        log_warning "Script opcional ausente, se omite: ${relative_path}"
        return 0
    fi

    [[ "${DRY_RUN}" == "true" ]] && script_args+=(--dry-run)

    log_section "Etapa: ${stage_name}"
    log_info "Script: ${relative_path}"

    if bash "${full_path}" "${script_args[@]}"; then
        log_success "Etapa '${stage_name}' completada."
        # EXECUTED_COUNT es global — la modificación en esta función es
        # intencional. No se invoca en subshell, así que no hay riesgo de perder
        # el valor. Si en el futuro run_stage se paraleliza, revisar este punto.
        EXECUTED_COUNT=$((EXECUTED_COUNT + 1))
    else
        local exit_code=$?
        log_error "Fallo crítico en etapa '${stage_name}' (exit code: ${exit_code})."
        log_error "Script: ${relative_path}"
        [[ -n "${LOG_FILE:-}" ]] && log_error "Consulta el log: ${LOG_FILE}"
        exit "${exit_code}"
    fi
}

print_summary() {
    local host_ip="$1"

    log_header "Instalación finalizada"
    log_info "Resumen:"
    log_info "  - Etapas ejecutadas: ${EXECUTED_COUNT}"
    log_info "  - IP del sistema:    ${host_ip}"
    log_info "  - Log de sesión:     ${LOG_FILE}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "[DRY-RUN] Simulación completada. No se aplicaron cambios reales."
    else
        log_warning "Recomendación: reinicia la Raspberry Pi para aplicar todos los cambios."
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    local host_ip=""
    local entry required_flag relative_path

    parse_args "$@"
    setup_environment

    host_ip="$(get_host_ip)"

    log_header "Iniciando Confiraspa"
    log_info "Repositorio:  ${REPO_ROOT}"
    log_info "IP detectada: ${host_ip}"
    log_info "Modo dry-run: ${DRY_RUN}"
    log_info "Log de sesión: ${LOG_FILE}"

    # Validar filtro --only antes de iterar para dar error temprano.
    if [[ -n "${ONLY_FILTER}" ]]; then
        log_info "Filtro --only activo: '${ONLY_FILTER}'"
        if ! stage_exists_for_filter; then
            log_error "Ninguna etapa coincide con el filtro: '${ONLY_FILTER}'"
            log_error "Valores válidos: basename sin .sh (ej. samba) o ruta relativa."
            exit 1
        fi
    fi

    for entry in "${STAGES[@]}"; do
        IFS='|' read -r required_flag relative_path <<< "${entry}"
        run_stage "${required_flag}" "${relative_path}"
    done

    if [[ "${EXECUTED_COUNT}" -eq 0 ]]; then
        log_error "No se ejecutó ninguna etapa. Revisa el filtro --only o el estado del pipeline."
        exit 1
    fi

    print_summary "${host_ip}"
}

main "$@"