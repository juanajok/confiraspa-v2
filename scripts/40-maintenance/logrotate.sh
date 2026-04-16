#!/usr/bin/env bash
# scripts/40-maintenance/logrotate.sh
# Configuración idempotente de logrotate y journald para Confiraspa.
#
# Genera reglas de rotación dinámicas desde logrotate_jobs.json y optimiza
# la configuración global de logrotate y systemd-journald para minimizar
# escritura en la SD de la Raspberry Pi.

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
readonly JOURNAL_CONF="/etc/systemd/journald.conf"
readonly MAX_JOURNAL_SIZE="100M"

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

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Habilitar compresión global en logrotate.conf (idempotente) ---
enable_global_compression() {
    if ! grep -q "^#compress" "${GLOBAL_CONF}" 2>/dev/null; then
        log_info "Compresión global ya habilitada en logrotate."
        return 0
    fi

    create_backup "${GLOBAL_CONF}"
    execute_cmd "sed -i 's/^#compress/compress/' '${GLOBAL_CONF}'" \
        "Habilitando compresión global en logrotate"
}

# --- Limitar tamaño de journald (protección SD) ---
# SystemMaxUse limita el espacio que journald ocupa en disco.
# En una RPi con SD, 100M es un compromiso entre diagnóstico y longevidad.
optimize_journald() {
    if grep -q "^SystemMaxUse=${MAX_JOURNAL_SIZE}" "${JOURNAL_CONF}" 2>/dev/null; then
        log_info "Journald ya está limitado a ${MAX_JOURNAL_SIZE}."
        return 0
    fi

    log_info "Ajustando SystemMaxUse a ${MAX_JOURNAL_SIZE} en journald..."
    create_backup "${JOURNAL_CONF}"

    if grep -q "^#\?SystemMaxUse=" "${JOURNAL_CONF}" 2>/dev/null; then
        # La línea existe (comentada o con otro valor) — sustituir in-place
        execute_cmd "sed -i 's/^[#]*SystemMaxUse=.*/SystemMaxUse=${MAX_JOURNAL_SIZE}/' '${JOURNAL_CONF}'" \
            "Actualizando SystemMaxUse en journald.conf"
    else
        # La línea no existe — añadir al final bajo [Journal]
        execute_cmd "bash -c 'echo \"SystemMaxUse=${MAX_JOURNAL_SIZE}\" >> \"${JOURNAL_CONF}\"'" \
            "Añadiendo SystemMaxUse a journald.conf"
    fi

    execute_cmd "systemctl restart systemd-journald" \
        "Reiniciando journald para aplicar límite"
}

# --- Extraer campos de un job JSON en una sola llamada jq ---
# En una RPi, cada fork+exec de jq es costoso. Consolidamos la extracción
# de todos los campos de un job en una sola invocación.
parse_job_fields() {
    local job="$1"

    # Extraer todos los campos en una línea TSV
    read -r JOB_NAME JOB_PATH JOB_ROTATE JOB_DAILY JOB_WEEKLY JOB_FREQUENCY \
         JOB_COMPRESS JOB_MISSINGOK JOB_NOTIFEMPTY JOB_COPYTRUNCATE JOB_CREATE \
        < <(echo "${job}" | jq -r '[
            .name,
            .path,
            (.rotate // 7 | tostring),
            (.daily // false | tostring),
            (.weekly // false | tostring),
            (.frequency // "daily"),
            (.compress // true | tostring),
            (.missingok // true | tostring),
            (.notifempty // true | tostring),
            (.copytruncate // false | tostring),
            (.create // "")
        ] | @tsv')
}

# --- Convertir campos del job a directivas logrotate ---
render_job_block() {
    local freq

    # Determinar frecuencia: flags booleanos tienen prioridad sobre .frequency
    if [[ "${JOB_DAILY}" == "true" ]]; then
        freq="daily"
    elif [[ "${JOB_WEEKLY}" == "true" ]]; then
        freq="weekly"
    else
        freq="${JOB_FREQUENCY}"
    fi

    # Mapear booleanos a directivas
    local compress_dir="compress"
    [[ "${JOB_COMPRESS}" != "true" ]] && compress_dir="nocompress"

    local missingok_dir="missingok"
    [[ "${JOB_MISSINGOK}" != "true" ]] && missingok_dir="nomissingok"

    local notifempty_dir="notifempty"
    [[ "${JOB_NOTIFEMPTY}" != "true" ]] && notifempty_dir="ifempty"

    log_info "  -> Generando regla: ${JOB_NAME} (${freq})"

    # Generar bloque — su root adm evita el error "insecure permissions"
    # que logrotate emite cuando el directorio padre no es propiedad de root.
    echo "${JOB_PATH} {"
    echo "    su root adm"
    echo "    ${freq}"
    echo "    rotate ${JOB_ROTATE}"
    echo "    ${compress_dir}"
    [[ "${compress_dir}" == "compress" ]] && echo "    delaycompress"
    echo "    ${missingok_dir}"
    echo "    ${notifempty_dir}"
    [[ "${JOB_COPYTRUNCATE}" == "true" ]] && echo "    copytruncate"
    [[ -n "${JOB_CREATE}" ]] && echo "    create ${JOB_CREATE}"
    echo "}"
    echo ""
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
    while IFS= read -r job; do
        parse_job_fields "${job}"
        render_job_block >> "${candidate}"
    done < <(jq -c '.jobs[]' "${JSON_CONFIG}")

    # Validar sintaxis con logrotate -d (debug mode, no ejecuta rotaciones)
    # logrotate -d puede reportar "stat of /var/log/X failed" si los logs no
    # existen aún — eso es normal en instalación fresca, no es un error real.
    log_info "Validando sintaxis generada..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "[DRY-RUN] Validación de sintaxis logrotate omitida (fichero no instalado)."
    else
        local val_output
        if val_output=$(logrotate -d "${candidate}" 2>&1); then
            log_success "Sintaxis validada correctamente."
        else
            if echo "${val_output}" | grep -q "error: stat of"; then
                log_warning "Algunos ficheros de log aún no existen (normal en instalación fresca)."
            else
                log_error "Error de sintaxis en la configuración generada:"
                echo "${val_output}" >&2
                exit 1
            fi
        fi
    fi

    # Instalar solo si hay cambios (idempotente)
    if [[ -f "${TARGET_FILE}" ]] && cmp -s "${TARGET_FILE}" "${candidate}"; then
        log_info "Reglas de logrotate sin cambios."
        return 0
    fi

    execute_cmd "cp '${candidate}' '${TARGET_FILE}'" \
        "Instalando reglas de logrotate en ${TARGET_FILE}"

    execute_cmd "chmod 644 '${TARGET_FILE}'" \
        "Ajustando permisos de ${TARGET_FILE}"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    local temp_dir=""

    trap 'rm -rf "${temp_dir:-}"' EXIT
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Optimización de Logs (Logrotate + Journal)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands sed grep systemctl logrotate

    ensure_package "jq"

    # --- 2. Optimización global ---
    enable_global_compression
    optimize_journald

    # --- 3. Reglas dinámicas desde JSON ---
    temp_dir="$(mktemp -d)"
    generate_dynamic_rules "${temp_dir}"

    log_success "Mantenimiento de logs finalizado."
}

main "$@"