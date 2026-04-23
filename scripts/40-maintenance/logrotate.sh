#!/usr/bin/env bash
# scripts/40-maintenance/logrotate.sh
# Configuración idempotente de logrotate y journald para Confiraspa.
#
# Genera reglas de rotación dinámicas desde logrotate_jobs.json y optimiza
# la configuración global de logrotate y systemd-journald para minimizar
# escritura en la SD de la Raspberry Pi y mantener trazabilidad de logs.
#
# Features:
#   - dateext + dateformat: ficheros rotados con fecha legible (YYYYMMDD)
#   - maxsize: rotación anticipada si el log crece más rápido del periodo
#   - Drop-in de journald: no modifica /etc/systemd/journald.conf (paquete)
#   - Validación logrotate -d antes de instalar

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
readonly JSON_CONFIG="${REPO_ROOT}/configs/static/logrotate_jobs.json"
readonly TARGET_FILE="/etc/logrotate.d/confiraspa-dynamic"
readonly GLOBAL_CONF="/etc/logrotate.conf"

readonly JOURNAL_DROPIN_DIR="/etc/systemd/journald.conf.d"
readonly JOURNAL_DROPIN_FILE="${JOURNAL_DROPIN_DIR}/10-confiraspa-limit.conf"

# Afinamiento de Journald (balance entre retención y longevidad de SD)
readonly JOURNAL_MAX_USE="100M"
readonly JOURNAL_MAX_FILE="10M"
readonly JOURNAL_RUNTIME_USE="50M"

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

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Habilitar compresión global en logrotate.conf ---
enable_global_compression() {
    if ! grep -q "^#compress" "${GLOBAL_CONF}" 2>/dev/null; then
        log_info "Compresión global ya habilitada en logrotate."
        return 0
    fi

    create_backup "${GLOBAL_CONF}"
    execute_cmd "sed -i 's/^#compress/compress/' '${GLOBAL_CONF}'" \
        "Habilitando compresión global en logrotate"
}

# --- Optimizar journald vía drop-in ---
# No modificar /etc/systemd/journald.conf directamente (pertenece al paquete
# systemd y cualquier update lo sobreescribe). Los drop-ins son la forma
# correcta de personalizar configuración de systemd.
optimize_journald() {
    local temp_dir="$1"
    local candidate="${temp_dir}/journald-dropin.candidate"

    cat > "${candidate}" <<EOF
# Generado por Confiraspa — límites de journald para proteger la SD
[Journal]
SystemMaxUse=${JOURNAL_MAX_USE}
SystemMaxFileSize=${JOURNAL_MAX_FILE}
RuntimeMaxUse=${JOURNAL_RUNTIME_USE}
EOF

    # Idempotencia: solo instalar si ha cambiado
    if [[ -f "${JOURNAL_DROPIN_FILE}" ]] && cmp -s "${JOURNAL_DROPIN_FILE}" "${candidate}"; then
        log_info "Drop-in de journald sin cambios."
        return 0
    fi

    execute_cmd "mkdir -p '${JOURNAL_DROPIN_DIR}'" \
        "Creando directorio drop-in de journald"

    if [[ -f "${JOURNAL_DROPIN_FILE}" ]]; then
        create_backup "${JOURNAL_DROPIN_FILE}"
    fi

    execute_cmd "cp '${candidate}' '${JOURNAL_DROPIN_FILE}'" \
        "Instalando drop-in de journald (SystemMaxUse=${JOURNAL_MAX_USE})"
    execute_cmd "chmod 644 '${JOURNAL_DROPIN_FILE}'" \
        "Permisos del drop-in"

    # RISK: Reiniciar journald rota los ficheros activos y genera un nuevo
    # journal. No se pierden logs pasados (se archivan), pero clientes que
    # estén leyendo journal en tiempo real (journalctl -f) pierden el stream.
    # Mitigación: impacto aceptable durante instalación planificada.
    execute_cmd "systemctl restart systemd-journald" \
        "Reiniciando journald para aplicar límites"
}

# --- Extraer campos de un job JSON en una sola llamada jq ---
# En una RPi, cada fork+exec de jq es costoso. Consolidamos la extracción
# de todos los campos de un job en una sola invocación.
parse_job_fields() {
    local job="$1"

    # Extraer todos los campos en una línea TSV
    read -r JOB_NAME JOB_PATH JOB_ROTATE JOB_DAILY JOB_WEEKLY \
         JOB_COMPRESS JOB_MISSINGOK JOB_NOTIFEMPTY \
         JOB_CREATE JOB_COPYTRUNCATE JOB_MAXSIZE \
        < <(echo "${job}" | jq -r '[
            .name,
            .path,
            (.rotate // 7 | tostring),
            (.daily // false | tostring),
            (.weekly // false | tostring),
            (.compress // true | tostring),
            (.missingok // true | tostring),
            (.notifempty // true | tostring),
            (.create // ""),
            (.copytruncate // false | tostring),
            (.maxsize // "")
        ] | @tsv')
}

# --- Convertir campos del job a directivas logrotate ---
render_job_block() {
    local frequency

    # Determinar frecuencia explícita: daily > weekly > default (weekly)
    if [[ "${JOB_DAILY}" == "true" ]]; then
        frequency="daily"
    elif [[ "${JOB_WEEKLY}" == "true" ]]; then
        frequency="weekly"
    else
        frequency="weekly"
    fi

    # Mapear booleanos a directivas
    local compress_dir="compress"
    [[ "${JOB_COMPRESS}" != "true" ]] && compress_dir="nocompress"

    local missingok_dir="missingok"
    [[ "${JOB_MISSINGOK}" != "true" ]] && missingok_dir="nomissingok"

    local notifempty_dir="notifempty"
    [[ "${JOB_NOTIFEMPTY}" != "true" ]] && notifempty_dir="ifempty"

    log_info "  -> Generando regla: ${JOB_NAME} (${frequency})"

    # Bloque de regla logrotate — su root adm evita warnings de
    # "insecure permissions" cuando el directorio padre no es de root.
    {
        echo "${JOB_PATH} {"
        echo "    su root adm"
        echo "    ${frequency}"
        echo "    rotate ${JOB_ROTATE}"
        echo "    dateext"
        echo "    dateformat -%Y%m%d"
        [[ -n "${JOB_MAXSIZE}" ]] && echo "    maxsize ${JOB_MAXSIZE}"
        echo "    ${compress_dir}"
        [[ "${compress_dir}" == "compress" ]] && echo "    delaycompress"
        echo "    ${missingok_dir}"
        echo "    ${notifempty_dir}"
        if [[ "${JOB_COPYTRUNCATE}" == "true" ]]; then
            echo "    # NOTE: copytruncate puede perder escrituras en alta concurrencia"
            echo "    copytruncate"
        fi
        [[ -n "${JOB_CREATE}" ]] && echo "    create ${JOB_CREATE}"
        echo "}"
        echo ""
    }
}

# --- Generar reglas dinámicas desde JSON ---
generate_dynamic_rules() {
    local temp_dir="$1"

    if [[ ! -f "${JSON_CONFIG}" ]]; then
        log_warning "Archivo de configuración no encontrado: ${JSON_CONFIG}. Saltando."
        return 0
    fi

    log_info "Generando reglas de logrotate desde JSON..."

    local candidate="${temp_dir}/confiraspa-dynamic.candidate"

    # Cabecera del fichero generado
    {
        echo "# Configuración generada automáticamente por Confiraspa"
        echo "# Generado el: $(date)"
        echo ""
    } > "${candidate}"

    # Procesar cada job del JSON
    local job
    while IFS= read -r job; do
        parse_job_fields "${job}"
        render_job_block >> "${candidate}"
    done < <(jq -c '.jobs[]' "${JSON_CONFIG}")

    # Validar sintaxis con logrotate -d (modo debug, no ejecuta rotaciones)
    # Errores comunes (stat failed) son normales en instalación fresca si
    # los logs aún no existen — los filtramos.
    log_info "Validando sintaxis generada..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "[DRY-RUN] Validación de sintaxis omitida (fichero no instalado)."
    else
        local val_output
        if val_output=$(logrotate -d "${candidate}" 2>&1); then
            log_success "Sintaxis validada correctamente."
        else
            if echo "${val_output}" | grep -q "error: stat of"; then
                log_warning "Algunos ficheros de log aún no existen (normal en instalación fresca)."
            else
                log_error "Error de sintaxis en la configuración generada:"
                log_error "${val_output}"
                exit 1
            fi
        fi
    fi

    # Instalar solo si hay cambios (idempotente)
    if [[ -f "${TARGET_FILE}" ]] && cmp -s "${TARGET_FILE}" "${candidate}"; then
        log_info "Reglas de logrotate sin cambios."
        return 0
    fi

    if [[ -f "${TARGET_FILE}" ]]; then
        create_backup "${TARGET_FILE}"
    fi

    execute_cmd "cp '${candidate}' '${TARGET_FILE}'" \
        "Instalando reglas de logrotate en ${TARGET_FILE}"
    execute_cmd "chmod 644 '${TARGET_FILE}'" \
        "Permisos del fichero de reglas"
    execute_cmd "chown root:root '${TARGET_FILE}'" \
        "Propietario root:root"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    local temp_dir=""

    trap 'rm -rf "${temp_dir:-}"' EXIT
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Optimización de Logs (Logrotate + Journald)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands sed grep systemctl logrotate mktemp cp cmp chown chmod

    ensure_package "jq"

    temp_dir="$(mktemp -d)"

    # --- 2. Compresión global en logrotate.conf ---
    enable_global_compression

    # --- 3. Drop-in de journald ---
    optimize_journald "${temp_dir}"

    # --- 4. Reglas dinámicas desde JSON ---
    generate_dynamic_rules "${temp_dir}"

    log_success "Mantenimiento de logs finalizado."
}

main "$@"