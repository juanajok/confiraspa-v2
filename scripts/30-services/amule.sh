#!/usr/bin/env bash
#
# scripts/30-services/amule.sh
# Descripción: Instalación e integración NAS de aMule Daemon (v4.0 - Final)
# Autor: Juan José Hipólito (Refactorizado v4.0 - Fixed Variable Scope)

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

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly SERVICE_NAME="amule-daemon"
readonly AMULE_USER="amule"
readonly AMULE_HOME="/var/lib/amule"
readonly CONF_DIR="${AMULE_HOME}/.aMule"
readonly TEMPLATE_FILE="${REPO_ROOT}/configs/static/templates/amule.conf"
readonly TARGET_CONF="${CONF_DIR}/amule.conf"
readonly DEFAULT_FILE="/etc/default/amule-daemon"
readonly AMULE_WEB_PORT="4711"

# Identidades NAS
readonly MEDIA_GROUP="${ARR_GROUP:-media}"

# Rutas de descarga (Prioridad .env -> Fallback)
export DIR_TORRENTS="${DIR_TORRENTS:-/media/DiscoDuro/torrents/completos}"
export DIR_TORRENTS_TEMP="${DIR_AMULE_TEMP:-/media/DiscoDuro/torrents/temp}"

DRY_RUN="${DRY_RUN:-false}"

# ===========================================================================
# MANEJO DE ERRORES
# ===========================================================================
on_error() {
    local exit_code="${1:-1}"
    log_error "Error en aMule (línea ${BASH_LINENO[0]}, exit code ${exit_code})."
    exit "${exit_code}"
}
trap 'on_error "$?"' ERR

# ===========================================================================
# FUNCIONES DE APOYO
# ===========================================================================

ensure_amule_user() {
    if ! id "${AMULE_USER}" &>/dev/null; then
        execute_cmd "useradd --system --home-dir ${AMULE_HOME} --shell /bin/false ${AMULE_USER}" \
            "Creando usuario de sistema: ${AMULE_USER}"
    fi

    # Integración en grupo media para acceso a discos externos
    assert_system_state "getent group '${MEDIA_GROUP}'" "El grupo ${MEDIA_GROUP} no existe."
    if ! id -nG "${AMULE_USER}" | grep -qw "${MEDIA_GROUP}"; then
        execute_cmd "usermod -aG ${MEDIA_GROUP} ${AMULE_USER}" "Añadiendo amule al grupo ${MEDIA_GROUP}"
    fi
}

ensure_directories() {
    log_info "Configurando estructura de directorios..."
    
    # Directorios internos (Protegidos)
    for dir in "${AMULE_HOME}" "${CONF_DIR}"; do
        execute_cmd "install -d -o ${AMULE_USER} -g ${AMULE_USER} -m 750 ${dir}" "Asegurando directorio interno: $dir"
    done

    # Directorios NAS (Compartidos con SetGID)
    for dir in "${DIR_TORRENTS}" "${DIR_TORRENTS_TEMP}"; do
        execute_cmd "install -d -o ${AMULE_USER} -g ${MEDIA_GROUP} -m 2775 ${dir}" "Asegurando directorio NAS: $dir"
        execute_cmd "chmod g+s ${dir}" "Activando SetGID en $dir"
    done
}

# ===========================================================================
# CONFIGURACIÓN
# ===========================================================================

setup_configs() {
    local temp_dir="$1"
    
    # 1. /etc/default/amule-daemon (Debe estar ANTES de arrancar para evitar error AMULED_USER)
    local candidate_default="${temp_dir}/amule-daemon.default"
    cat <<EOF > "${candidate_default}"
# Generado por Confiraspa
AMULED_USER="${AMULE_USER}"
AMULED_HOME="${AMULE_HOME}"
EOF
    execute_cmd "cp ${candidate_default} ${DEFAULT_FILE}" "Instalando configuración de demonio"

    # 2. Generación de amule.conf (Inyección de variables)
    log_info "Calculando hashes y renderizando amule.conf..."
    local amule_pass_md5 amule_web_pass_md5
    amule_pass_md5=$(printf '%s' "${AMULE_PASS:-raspberry}" | md5sum | awk '{print $1}')
    amule_web_pass_md5=$(printf '%s' "${AMULE_WEB_PASS:-raspberry}" | md5sum | awk '{print $1}')

    # Exportación explícita para envsubst
    export AMULE_HOME DIR_TORRENTS DIR_TORRENTS_TEMP HOSTNAME
    export AMULE_PASS_MD5="${amule_pass_md5}"
    export AMULE_WEB_PASS_MD5="${amule_web_pass_md5}"

    local candidate_conf="${temp_dir}/amule.conf"
    envsubst '${AMULE_HOME} ${DIR_TORRENTS} ${DIR_TORRENTS_TEMP} ${HOSTNAME} ${AMULE_PASS_MD5} ${AMULE_WEB_PASS_MD5}' \
        < "${TEMPLATE_FILE}" > "${candidate_conf}"

    execute_cmd "install -o ${AMULE_USER} -g ${AMULE_USER} -m 600 ${candidate_conf} ${TARGET_CONF}" "Instalando amule.conf"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    validate_root
    require_system_commands install systemctl id jq md5sum envsubst

    log_section "Configuración de Red P2P (aMule)"

    # 1. Software
    ensure_package "amule-daemon"
    ensure_package "amule-utils"

    # 2. Identidad y Carpetas
    ensure_amule_user
    ensure_directories

    # 3. Preparación de Configuración
    local temp_work
    temp_work=$(mktemp -d)
    trap 'rm -rf ${temp_work}' EXIT
    
    setup_configs "${temp_work}"

    # 4. Hardening de Permisos (UMask para el servicio)
    local override_dir="/etc/systemd/system/${SERVICE_NAME}.service.d"
    execute_cmd "mkdir -p ${override_dir}" "Creando directorio de override"
    echo -e "[Service]\nUMask=0002" | execute_cmd "tee ${override_dir}/override.conf" "Aplicando UMask 0002"

    # 5. Arranque
    execute_cmd "systemctl daemon-reload" "Recargando systemd"
    execute_cmd "systemctl enable ${SERVICE_NAME}" "Habilitando servicio"
    execute_cmd "systemctl restart ${SERVICE_NAME}" "Reiniciando aMule con nueva configuración"

    # 6. Verificación (Timeout de 30s para primer arranque)
    if wait_for_service "localhost" "${AMULE_WEB_PORT}" "aMule Web UI" 30; then
        log_success "aMule operativo en http://$(get_ip_address):${AMULE_WEB_PORT}"
    else
        log_error "aMule no responde. Revisa el log interno en ${AMULE_HOME}/.aMule/logfile"
        exit 1
    fi
}

main "$@"