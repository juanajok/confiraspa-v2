#!/usr/bin/env bash
# scripts/30-services/amule.sh
# Configuración idempotente de aMule Daemon para Confiraspa.
#
# aMule usa MD5 para hashear sus contraseñas internas (ECPassword, WebServer Password).
# No es un estándar criptográfico moderno, pero es lo que el protocolo eMule/Kademlia
# exige — no hay alternativa sin parchear el código fuente.

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

# Cargar .env si no estamos bajo install.sh (ej: --only amule)
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

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
# Grupo multimedia compartido con Sonarr/Radarr/Samba — viene de .env o default
readonly MEDIA_GROUP="${ARR_GROUP:-media}"

# ===========================================================================
# FUNCIONES LOCALES
# ===========================================================================

# --- Error handler ---
on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."

    # Restaurar configuración si teníamos backup
    if [[ -n "${backup_file:-}" && -f "${backup_file:-}" ]]; then
        cp "${backup_file}" "${TARGET_CONF}" 2>/dev/null || true
        log_warning "Configuración anterior restaurada desde backup."
    fi
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

# --- Validar comandos del SO base (siempre deben existir) ---
require_system_commands() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Comando requerido del sistema no disponible: ${cmd}"
            exit 1
        fi
    done
}

# --- Validar comandos del paquete instalado (se omiten en dry-run) ---
require_service_commands() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "[DRY-RUN] Omitiendo verificación de comandos de servicio: $*"
        return 0
    fi
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Comando del servicio no disponible: ${cmd}"
            exit 1
        fi
    done
}

# --- Validar variables de entorno requeridas ---
require_env_vars() {
    local var_name
    for var_name in "$@"; do
        local value="${!var_name:-}"
        if [[ -z "${value}" ]]; then
            log_error "Variable de entorno requerida no definida: ${var_name}"
            exit 1
        fi
        # Detectar valores placeholder sin configurar
        if [[ "${value}" == *"TuPassword"* || "${value}" == "ChangeMe!" ]]; then
            log_error "Variable '${var_name}' tiene valor placeholder. Edita el .env."
            exit 1
        fi
    done
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Crear usuario de sistema para aMule e integrarlo en el ecosistema NAS ---
ensure_amule_user() {
    # 1. Crear usuario si no existe
    if id "${AMULE_USER}" &>/dev/null; then
        log_info "Usuario '${AMULE_USER}' ya existe."
    elif [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "[DRY-RUN] Usuario '${AMULE_USER}' no existe (normal en simulación)."
        execute_cmd "useradd --system --home-dir '${AMULE_HOME}' --shell /bin/false '${AMULE_USER}'" \
            "Creando usuario de sistema: ${AMULE_USER}"
    else
        execute_cmd "useradd --system --home-dir '${AMULE_HOME}' --shell /bin/false '${AMULE_USER}'" \
            "Creando usuario de sistema: ${AMULE_USER}"
    fi

    # 2. INTEGRACIÓN NAS: añadir amule al grupo multimedia
    # Sin esto Sonarr/Radarr reciben Permission Denied al intentar mover
    # archivos descargados, y Samba no puede servirlos en Windows/Mac.
    if [[ "${DRY_RUN}" == "true" ]]; then
        execute_cmd "usermod -aG '${MEDIA_GROUP}' '${AMULE_USER}'" \
            "Añadiendo ${AMULE_USER} al grupo NAS: ${MEDIA_GROUP}"
        return 0
    fi

    if ! getent group "${MEDIA_GROUP}" &>/dev/null; then
        log_error "El grupo '${MEDIA_GROUP}' no existe. Ejecuta antes el script de usuarios/grupos."
        exit 1
    fi

    if ! id -nG "${AMULE_USER}" | grep -qw "${MEDIA_GROUP}"; then
        execute_cmd "usermod -aG '${MEDIA_GROUP}' '${AMULE_USER}'" \
            "Añadiendo ${AMULE_USER} al grupo NAS: ${MEDIA_GROUP}"
    else
        log_info "Usuario '${AMULE_USER}' ya pertenece al grupo '${MEDIA_GROUP}'."
    fi
}

# --- Crear directorios con permisos correctos ---
ensure_amule_directories() {
    local dir

    # Directorios internos — solo aMule accede (config, claves, logs internes)
    # SECURITY: 750, propietario amule:amule — ningún otro usuario entra aquí.
    for dir in "${AMULE_HOME}" "${CONF_DIR}"; do
        execute_cmd "install -d -o '${AMULE_USER}' -g '${AMULE_USER}' -m 750 '${dir}'" \
            "Asegurando directorio interno: ${dir}"
    done

    # Directorios NAS — compartidos con el grupo media (Sonarr/Radarr/Samba)
    # SECURITY: 2775 (no 777) — escritura solo para propietario y grupo.
    # SetGID (bit 2xxx): los archivos que aMule crea heredan el grupo media
    # automáticamente, sin necesidad de chown posterior.
    for dir in "${DIR_TORRENTS}" "${DIR_TORRENTS_TEMP}"; do
        execute_cmd "install -d -o '${AMULE_USER}' -g '${MEDIA_GROUP}' -m 2775 '${dir}'" \
            "Asegurando directorio NAS: ${dir}"
        # chmod g+s explícito: install -m no siempre propaga el bit setgid en todos los sistemas.
        execute_cmd "chmod g+s '${dir}'" \
            "Activando SetGID en: ${dir}"
    done
}

# --- Override de systemd: forzar UMask=0002 ---
# Por defecto los daemons crean archivos con UMask=0022 → permisos 644.
# Con UMask=0002 los archivos nacen con 664 (grupo puede escribir/borrar),
# lo que permite a Sonarr/Radarr mover y eliminar descargas completadas.
install_systemd_override() {
    local temp_dir="$1"
    local override_dir="/etc/systemd/system/${SERVICE_NAME}.service.d"
    local override_file="${override_dir}/override.conf"
    local candidate="${temp_dir}/systemd-override.conf"

    cat > "${candidate}" <<EOF
# Generado por Confiraspa — no editar manualmente
[Service]
UMask=0002
EOF

    execute_cmd "mkdir -p '${override_dir}'" \
        "Creando directorio de override de systemd"

    if [[ -f "${override_file}" ]] && cmp -s "${override_file}" "${candidate}"; then
        log_info "Override de systemd sin cambios."
        return 0
    fi

    execute_cmd "cp '${candidate}' '${override_file}'" \
        "Instalando override de UMask para ${SERVICE_NAME}"
}

# --- Configurar /etc/default/amule-daemon ---
# IMPORTANTE: Debe ejecutarse ANTES de cualquier systemctl stop/start/restart.
# El init script LSB de aMule lee este fichero y aborta si AMULED_USER no está definido.
install_default_file() {
    local temp_dir="$1"
    local candidate="${temp_dir}/amule-daemon.default"

    cat > "${candidate}" <<EOF
# Generado por Confiraspa — no editar manualmente
AMULED_USER="${AMULE_USER}"
AMULED_HOME="${AMULE_HOME}"
EOF

    if [[ -f "${DEFAULT_FILE}" ]] && cmp -s "${DEFAULT_FILE}" "${candidate}"; then
        log_info "Archivo ${DEFAULT_FILE} sin cambios."
        return 0
    fi

    execute_cmd "cp '${candidate}' '${DEFAULT_FILE}'" \
        "Instalando configuración de demonio: ${DEFAULT_FILE}"
}

# --- Generar configuración candidata en directorio temporal ---
render_amule_config() {
    local temp_dir="$1"
    local candidate="${temp_dir}/amule.conf.candidate"

    # Calcular hashes MD5 de las contraseñas (requisito del protocolo eMule)
    local amule_pass_md5 amule_web_pass_md5 current_hostname
    amule_pass_md5="$(printf '%s' "${AMULE_PASS}" | md5sum | awk '{print $1}')"
    amule_web_pass_md5="$(printf '%s' "${AMULE_WEB_PASS}" | md5sum | awk '{print $1}')"
    current_hostname="$(hostname)"

    # Exportar para envsubst — solo las variables que la plantilla necesita
    export AMULE_HOME DIR_TORRENTS DIR_TORRENTS_TEMP AMULE_PASS_MD5="${amule_pass_md5}" AMULE_WEB_PASS_MD5="${amule_web_pass_md5}" HOSTNAME="${current_hostname}"

    if [[ ! -f "${TEMPLATE_FILE}" ]]; then
        log_error "Plantilla no encontrada: ${TEMPLATE_FILE}"
        exit 1
    fi

    envsubst '${AMULE_HOME} ${DIR_TORRENTS} ${DIR_TORRENTS_TEMP} ${HOSTNAME} ${AMULE_PASS_MD5} ${AMULE_WEB_PASS_MD5}' \
        < "${TEMPLATE_FILE}" > "${candidate}"

    echo "${candidate}"
}

# --- Instalar configuración solo si ha cambiado (idempotente) ---
install_config_if_changed() {
    local candidate="$1"

    # Si la configuración actual es idéntica, no tocar nada
    if [[ -f "${TARGET_CONF}" ]] && cmp -s "${TARGET_CONF}" "${candidate}"; then
        log_info "Configuración sin cambios. No se modifica amule.conf."
        return 1  # Señal de que no hubo cambios (para decidir si reiniciar)
    fi

    # Detener servicio antes de escribir — aMule puede sobreescribir amule.conf al cerrarse.
    # NOTA: install_default_file ya se ejecutó, así que el init script tiene AMULED_USER.
    if check_service_active "${SERVICE_NAME}"; then
        execute_cmd "systemctl stop '${SERVICE_NAME}'" \
            "Deteniendo ${SERVICE_NAME} antes de actualizar configuración"
    fi

    # Backup de la configuración existente — guardar ruta para rollback en on_error
    if [[ -f "${TARGET_CONF}" ]]; then
        backup_file="${TARGET_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
        execute_cmd "cp -a '${TARGET_CONF}' '${backup_file}'" \
            "Backup de configuración existente"
    fi

    # Instalar la nueva configuración
    execute_cmd "cp '${candidate}' '${TARGET_CONF}'" \
        "Instalando nueva configuración amule.conf"

    execute_cmd "chown '${AMULE_USER}:${AMULE_USER}' '${TARGET_CONF}'" \
        "Asignando propietario a amule.conf"

    # Permisos 600: solo el propietario puede leer/escribir (contiene hashes de contraseñas)
    execute_cmd "chmod 600 '${TARGET_CONF}'" \
        "Protegiendo amule.conf (permisos 600)"

    return 0  # Señal de que hubo cambios
}

# --- Arrancar y verificar servicio ---
start_and_verify() {
    execute_cmd "systemctl daemon-reload" "Recargando systemd"
    execute_cmd "systemctl enable '${SERVICE_NAME}'" "Habilitando ${SERVICE_NAME}"

    # Siempre restart: garantiza subida limpia con los ficheros recién escritos
    execute_cmd "systemctl restart '${SERVICE_NAME}'" "Arrancando ${SERVICE_NAME}"
}

# --- Comprobaciones post-instalación ---
post_checks() {
    # aMule puede ser lento en el primer arranque (genera archivos .dat y claves).
    # En RPi con SD lenta, 30s es más seguro que 15s.
    if ! wait_for_service "localhost" "${AMULE_WEB_PORT}" "aMule Web UI" 30; then
        log_error "aMule no responde en el puerto ${AMULE_WEB_PORT}."
        log_error "Diagnóstico: journalctl -u ${SERVICE_NAME} -n 50"
        log_error "Log interno: ${AMULE_HOME}/.aMule/logfile"
        exit 1
    fi

    local ip
    ip="$(get_ip_address)"

    log_success "aMule Daemon operativo."
    log_info "  Web UI:  http://${ip}:${AMULE_WEB_PORT}"
    log_info "  EC Port: 4712 (para control remoto desde aMule GUI)"
    log_info "  Datos:   ${DIR_TORRENTS}"
    log_info "  Temp:    ${DIR_TORRENTS_TEMP}"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    # --- Variables de estado ---
    local backup_file=""
    local temp_dir=""

    # Limpieza garantizada al salir (éxito o error)
    trap 'rm -rf "${temp_dir:-}"' EXIT
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Configuración de Red P2P (aMule)"

    # --- 1. Validaciones previas ---
    validate_root
    require_system_commands install systemctl id getent usermod awk md5sum hostname grep

    # Variables del .env necesarias
    AMULE_PASS="${AMULE_PASS:-}"
    AMULE_WEB_PASS="${AMULE_WEB_PASS:-}"
    require_env_vars AMULE_PASS AMULE_WEB_PASS DIR_TORRENTS DIR_TORRENTS_TEMP

    # --- 2. Instalación de paquetes ---
    ensure_package "amule-daemon"
    ensure_package "amule-utils"
    ensure_package "gettext-base"     # Para envsubst

    # Verificar comandos que provee el paquete (solo en producción)
    require_service_commands amuled

    # --- 3. Usuario y directorios ---
    log_info "Configurando entorno de usuario..."
    ensure_amule_user
    ensure_amule_directories

    # --- 4. Fichero default — ANTES de cualquier interacción con systemctl ---
    # El init script LSB de amule-daemon lee /etc/default/amule-daemon
    # y aborta con "AMULED_USER not set" si no existe. Esto afecta tanto
    # a stop como a start, así que debe estar en su sitio antes del paso 5.
    temp_dir="$(mktemp -d)"
    install_default_file "${temp_dir}"

    # --- 5. Override de systemd (UMask para herencia de permisos NAS) ---
    # Debe instalarse antes de daemon-reload + restart en el paso 7.
    install_systemd_override "${temp_dir}"

    # --- 6. Generar e instalar configuración de aMule ---
    local config_changed=false
    local candidate
    candidate="$(render_amule_config "${temp_dir}")"

    if install_config_if_changed "${candidate}"; then
        config_changed=true
    fi

    # --- 7. Arranque y verificación ---
    if [[ "${config_changed}" == "true" ]]; then
        log_info "Configuración actualizada — reiniciando servicio..."
        start_and_verify
    else
        # Asegurar que está habilitado y corriendo aunque no haya cambios
        execute_cmd "systemctl enable '${SERVICE_NAME}'" "Asegurando servicio habilitado"
        if ! check_service_active "${SERVICE_NAME}"; then
            start_and_verify
        else
            log_info "Servicio ya activo y sin cambios de configuración."
        fi
    fi

    post_checks
}

main "$@"