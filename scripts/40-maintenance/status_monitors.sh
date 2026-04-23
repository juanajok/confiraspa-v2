#!/usr/bin/env bash
# scripts/40-maintenance/status_monitors.sh
# Configuración idempotente de la monitorización global de Confiraspa.
#
# Genera los ficheros .serv para el módulo "System and Server Status" de Webmin.
# Incluye validación de rango de puertos (1-65535), prevención de colisiones
# y recolección de basura O(1) puramente en Bash (nullglob y manipulación de strings).

set -euo pipefail
IFS=$'\n\t'

# ===========================================================================
# CABECERA UNIVERSAL
# ===========================================================================
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    export REPO_ROOT
fi

source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly MONITOR_DIR="/etc/webmin/status/services"

# Mapa de variables del .env frente a su nombre visual en Webmin
readonly MAPA_SERVICIOS=(
    "CALIBRE_PORT|Calibre"
    "SONARR_PORT|Sonarr"
    "RADARR_PORT|Radarr"
    "LIDARR_PORT|Lidarr"
    "READARR_PORT|Readarr"
    "PROWLARR_PORT|Prowlarr"
    "WHISPARR_PORT|Whisparr"
    "BAZARR_PORT|Bazarr"
    "TRANSMISSION_WEB_PORT|Transmission"
    "PLEX_PORT|Plex"
    "AMULE_WEB_PORT|aMule WebUI"
)

TEMP_DIR=""

# ===========================================================================
# FUNCIONES LOCALES (TRAPS Y ARGS)
# ===========================================================================

on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"
    log_error "Error en '${source_file##*/}' (línea ${line_no}, exit code ${exit_code})."
}

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

trap 'on_error "$?"' ERR
trap cleanup EXIT

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

configurar_monitores() {
    if [[ ! -d "/etc/webmin" ]]; then
        log_warning "Webmin no detectado en el sistema. Omitiendo configuración de monitores."
        return 0
    fi

    execute_cmd "mkdir -p '${MONITOR_DIR}'" "Asegurando directorio de monitores de Webmin"

    TEMP_DIR="$(mktemp -d)"

    local entry var_name desc port target_id candidate_file target_file
    local -a desired_ids=()
    local changes_made=0

    # --- 1. CREACIÓN Y ACTUALIZACIÓN DE MONITORES ---
    for entry in "${MAPA_SERVICIOS[@]}"; do
        IFS='|' read -r var_name desc <<< "${entry}"

        port="${!var_name:-}"
        [[ -z "${port}" ]] && continue

        # Validación estricta: Numérico y dentro del rango de puertos TCP válido
        if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            log_warning "Puerto inválido (fuera de rango 1-65535) para ${desc}: '${port}'. Omitiendo."
            continue
        fi

        target_id="confiraspa_${var_name}_${port}"
        desired_ids+=("${target_id}")

        candidate_file="${TEMP_DIR}/${target_id}.serv"
        target_file="${MONITOR_DIR}/${target_id}.serv"

        cat <<EOF > "${candidate_file}"
id=${target_id}
type=tcp
port=${port}
host=127.0.0.1
desc=Confiraspa: ${desc}
EOF

        if [[ -f "${target_file}" ]] && cmp -s "${candidate_file}" "${target_file}"; then
            log_info "Monitor OK: ${desc} (Puerto ${port})"
        else
            if [[ "${DRY_RUN}" == "true" ]]; then
                log_info "[DRY-RUN] Instalaría monitor para ${desc} en el puerto ${port}."
            else
                execute_cmd "cp '${candidate_file}' '${target_file}'" "Instalando monitor: ${desc}"
                execute_cmd "chmod 600 '${target_file}'" "Permisos 600 en monitor: ${desc}"
                execute_cmd "chown root:root '${target_file}'" "Propietario root en monitor: ${desc}"
                changes_made=1
            fi
        fi
    done

    # --- 2. LIMPIEZA DE MONITORES OBSOLETOS (Garbage Collection O(1)) ---
    local -A desired_map
    local id
    for id in "${desired_ids[@]:-}"; do
        desired_map["$id"]=1
    done

    local existing fname
    
    # Activamos nullglob para evitar que devuelva el patrón literal si no hay ficheros
    shopt -s nullglob
    for existing in "${MONITOR_DIR}"/confiraspa_*.serv; do
        
        # Manipulación pura de Bash (sin fork a basename)
        fname="${existing##*/}"     # Extrae solo el nombre del archivo
        fname="${fname%.serv}"      # Elimina la extensión .serv

        if [[ -z "${desired_map[$fname]:-}" ]]; then
            if [[ "${DRY_RUN}" == "true" ]]; then
                log_info "[DRY-RUN] Eliminaría monitor obsoleto: ${fname}"
            else
                execute_cmd "rm -f '${existing}'" "Eliminando monitor obsoleto: ${fname}"
                changes_made=1
            fi
        fi
    done
    # Restauramos el comportamiento estándar del globbing (buena práctica)
    shopt -u nullglob

    # --- 3. REINICIO CONDICIONAL ---
    if [[ "${changes_made}" -eq 1 ]]; then
        if systemctl is-active --quiet webmin; then
            execute_cmd "systemctl restart webmin" "Recargando Webmin con los nuevos monitores"
        else
            log_warning "Webmin no está activo. Los monitores se cargarán automáticamente en el próximo arranque."
        fi
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    parse_args "$@"
    log_section "Configuración de Observabilidad (Monitores de Webmin)"

    validate_root
    # 'basename' eliminado de las dependencias requeridas
    require_system_commands systemctl cmp mkdir cat cp chmod chown rm

    configurar_monitores

    if [[ "${DRY_RUN}" != "true" ]]; then
        log_success "Observabilidad configurada correctamente."
    else
        log_success "[DRY-RUN] Simulación de observabilidad completada."
    fi
}

main "$@"