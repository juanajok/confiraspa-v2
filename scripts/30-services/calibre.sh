#!/usr/bin/env bash
# scripts/30-services/calibre.sh
# Configuración idempotente de Calibre GUI con Content Server integrado.
#
# MODELO A — GUI con servidor integrado:
#   - Calibre GUI arranca con autostart al iniciar sesión gráfica.
#   - El Content Server se activa DENTRO de la GUI (gui.py.json: autolaunch_server).
#   - No hay servicio systemd independiente (evita conflicto SQLite en metadata.db).
#
# WIZARD BYPASS: Inyecta installation_uuid + language + library_path en global.py.
# CONTENT SERVER: Modifica o crea gui.py.json (no server.py, que Calibre ignora).

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

if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly BASE_DIR="/opt/calibre"
readonly INSTALL_DIR="${BASE_DIR}/calibre"
readonly CALIBRE_GUI_BINARY="${INSTALL_DIR}/calibre"
readonly CALIBREDB_BINARY="${INSTALL_DIR}/calibredb"
readonly CALIBRE_USER="calibre"
readonly GUI_USER="${SYS_USER:-pi}"
readonly MEDIA_GROUP="${ARR_GROUP:-media}"
readonly CALIBRE_PORT="${CALIBRE_PORT:-8083}"
readonly LIBRARY_PATH="${DIR_BOOKS:-/media/WDElements/Libros}"
readonly INSTALLER_URL="https://download.calibre-ebook.com/linux-installer.sh"
readonly LEGACY_SERVICE="calibre-server"
readonly MIN_DISK_SPACE_MB=512

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

validate_architecture() {
    local arch
    arch=$(uname -m)
    if [[ "${arch}" != "aarch64" && "${arch}" != "x86_64" ]]; then
        log_error "Arquitectura no soportada: ${arch}. Calibre requiere 64 bits."
        exit 1
    fi
    log_info "Arquitectura: ${arch}"
}

# --- Validar variables del .env necesarias para este script ---
validate_env_vars() {
    validate_var "SYS_USER" "${SYS_USER:-}"
    validate_var "ARR_GROUP" "${ARR_GROUP:-}"
    # DIR_BOOKS es opcional — si no existe, usa el default
    # CALIBRE_PORT es opcional — default 8083
}

install_dependencies() {
    log_info "Instalando dependencias..."
    local deps=(
        wget python3 xz-utils xdg-utils
        libxcb-cursor0 libxcb-xinerama0 libxkbcommon-x11-0
        libegl1 libopengl0 libgl1 libxcomposite1
    )
    local dep
    for dep in "${deps[@]}"; do
        ensure_package "${dep}"
    done
}

ensure_calibre_user() {
    if id "${CALIBRE_USER}" &>/dev/null; then
        log_info "Usuario '${CALIBRE_USER}' ya existe."
    else
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "[DRY-RUN] Usuario '${CALIBRE_USER}' no existe (normal en simulación)."
            execute_cmd "useradd --system --shell /usr/sbin/nologin -m --home-dir /var/lib/calibre '${CALIBRE_USER}'" \
                "Creando usuario: ${CALIBRE_USER}"
            return 0
        fi
        execute_cmd "useradd --system --shell /usr/sbin/nologin -m --home-dir /var/lib/calibre '${CALIBRE_USER}'" \
            "Creando usuario: ${CALIBRE_USER}"
    fi

    if id "${CALIBRE_USER}" &>/dev/null && \
       ! id -nG "${CALIBRE_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx "${MEDIA_GROUP}"; then
        execute_cmd "usermod -aG '${MEDIA_GROUP}' '${CALIBRE_USER}'" \
            "Añadiendo ${CALIBRE_USER} al grupo ${MEDIA_GROUP}"
    fi

    if id "${GUI_USER}" &>/dev/null && \
       ! id -nG "${GUI_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx "${MEDIA_GROUP}"; then
        execute_cmd "usermod -aG '${MEDIA_GROUP}' '${GUI_USER}'" \
            "Añadiendo ${GUI_USER} al grupo ${MEDIA_GROUP}"
    fi
}

install_calibre() {
    if [[ -x "${CALIBRE_GUI_BINARY}" ]]; then
        log_info "Calibre ya instalado en ${INSTALL_DIR}."
        return 0
    fi

    log_info "Instalando Calibre desde el instalador oficial..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Se descargaría e instalaría Calibre en ${BASE_DIR}."
        return 0
    fi

    # Comprobar espacio antes de descargar (~500MB necesarios)
    if ! check_disk_space "${BASE_DIR%/*}" "${MIN_DISK_SPACE_MB}"; then
        log_error "Espacio insuficiente para instalar Calibre (mínimo ${MIN_DISK_SPACE_MB}MB)."
        exit 1
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"

    # SECURITY: Descarga vía download_secure (retry + verificación).
    # No se usa SHA256 porque el instalador cambia con cada release.
    local installer="${temp_dir}/calibre-installer.sh"
    if ! download_secure "${INSTALLER_URL}" "${installer}"; then
        log_error "Fallo al descargar el instalador de Calibre."
        rm -rf "${temp_dir}"
        exit 1
    fi

    execute_cmd "mkdir -p '${BASE_DIR}'" "Creando directorio de instalación"

    log_info "Ejecutando instalador (puede tardar varios minutos en RPi)..."
    if sh "${installer}" install_dir="${BASE_DIR}" isolated=y >> "${LOG_FILE:-/dev/null}" 2>&1; then
        log_success "Instalador completado."
    else
        log_error "El instalador de Calibre falló."
        rm -rf "${temp_dir}"
        exit 1
    fi

    rm -rf "${temp_dir}"

    if [[ ! -x "${CALIBRE_GUI_BINARY}" ]]; then
        log_error "Binario no encontrado: ${CALIBRE_GUI_BINARY}"
        exit 1
    fi

    log_success "Calibre instalado en ${INSTALL_DIR}."
}

initialize_library() {
    log_info "Verificando biblioteca: ${LIBRARY_PATH}"

    execute_cmd "install -d -o '${GUI_USER}' -g '${MEDIA_GROUP}' -m 2775 '${LIBRARY_PATH}'" \
        "Asegurando directorio de biblioteca"

    if [[ -f "${LIBRARY_PATH}/metadata.db" ]]; then
        log_success "Biblioteca existente detectada (metadata.db). Preservando datos."
    else
        log_warning "No se encontró metadata.db. Inicializando biblioteca vacía..."

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY-RUN] Se inicializaría biblioteca con calibredb."
            return 0
        fi

        if [[ -x "${CALIBREDB_BINARY}" ]]; then
            # calibredb puede fallar legítimamente en primera instalación si faltan dependencias Qt. 
            # Ejecutamos con sudo -u para que metadata.db nazca con permisos correctos.
            if sudo -u "${GUI_USER}" "${CALIBREDB_BINARY}" add --with-library "${LIBRARY_PATH}" --empty >> "${LOG_FILE:-/dev/null}" 2>&1; then
                log_success "Biblioteca inicializada."
            else
                local rc=$?
                log_warning "calibredb falló (exit code: ${rc}). Se creará al abrir la GUI."
            fi
        else
            log_warning "calibredb no disponible. Biblioteca se inicializará al primer uso."
        fi
    fi

    execute_cmd "chown '${GUI_USER}:${MEDIA_GROUP}' '${LIBRARY_PATH}'" \
        "Propietario de la biblioteca: ${GUI_USER}"

    if [[ -f "${LIBRARY_PATH}/metadata.db" ]]; then
        execute_cmd "chown '${GUI_USER}:${MEDIA_GROUP}' '${LIBRARY_PATH}/metadata.db'" \
            "Propietario de metadata.db: ${GUI_USER}"
    fi
}

# RISK: Deshabilita y elimina el servicio calibre-server standalone.
# Si se re-ejecuta en un sistema que depende de Modelo B (headless 24/7),
# el Content Server dejará de funcionar hasta que se abra la GUI.
# Mitigación: el servicio se puede restaurar volviendo a ejecutar el script
# en Modelo B, o manualmente con systemctl enable calibre-server.
disable_legacy_service() {
    if systemctl is-enabled --quiet "${LEGACY_SERVICE}" 2>/dev/null; then
        log_warning "Servicio standalone '${LEGACY_SERVICE}' detectado. Deshabilitando."

        if check_service_active "${LEGACY_SERVICE}"; then
            execute_cmd "systemctl stop '${LEGACY_SERVICE}'" "Deteniendo ${LEGACY_SERVICE}"
        fi
        execute_cmd "systemctl disable '${LEGACY_SERVICE}'" "Deshabilitando ${LEGACY_SERVICE}"
    fi

    local service_file="/etc/systemd/system/${LEGACY_SERVICE}.service"
    if [[ -f "${service_file}" ]]; then
        # RISK: Eliminación del unit file. Si el usuario necesita volver a
        # Modelo B, deberá regenerarlo ejecutando la variante del script.
        execute_cmd "rm -f '${service_file}'" "Eliminando unit file legacy"
        execute_cmd "systemctl daemon-reload" "Recargando systemd"
    fi
}

# --- Activar Content Server integrado en la GUI ---
# Calibre almacena autolaunch_server en gui.py.json (no en server.py).
preseed_server_config() {
    local home_dir
    home_dir=$(getent passwd "${GUI_USER}" 2>/dev/null | cut -d: -f6) || home_dir="/home/${GUI_USER}"
    local config_dir="${home_dir}/.config/calibre"
    local gui_json="${config_dir}/gui.py.json"

    execute_cmd "install -d -o '${GUI_USER}' -g '${GUI_USER}' -m 755 '${config_dir}'" \
        "Directorio de configuración Calibre"

    # Idempotencia: ya activado, no tocar
    if [[ -f "${gui_json}" ]] && grep -q '"autolaunch_server": true' "${gui_json}"; then
        log_info "Content Server ya activado en GUI (puerto ${CALIBRE_PORT})."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Activaría autolaunch_server en gui.py.json"
        return 0
    fi

    if [[ -f "${gui_json}" ]]; then
        create_backup "${gui_json}"
        execute_cmd "sed -i 's/\"autolaunch_server\": false/\"autolaunch_server\": true/' '${gui_json}'" \
            "Activando autolaunch_server en gui.py.json"
        execute_cmd "chown '${GUI_USER}:${GUI_USER}' '${gui_json}'" \
            "Propietario de gui.py.json"
        log_success "Content Server activado (autolaunch_server: true)."
    else
        # Primera instalación. Creamos el JSON mínimo para que el servidor arranque.
        log_info "gui.py.json no existe. Creando configuración inicial..."
        execute_cmd "echo '{\"autolaunch_server\": true}' > '${gui_json}'" \
            "Creando gui.py.json con autolaunch_server activo"
        execute_cmd "chown '${GUI_USER}:${GUI_USER}' '${gui_json}'" \
            "Propietario de gui.py.json"
        log_success "Content Server activado en nueva instalación."
    fi
}

# --- Bypass del Welcome Wizard ---
# El wizard salta si falta installation_uuid O library_path en global.py.
# Inyectamos ambos + language para que Calibre arranque directo.
preseed_gui_config() {
    log_info "Pre-configurando GUI para saltar el Welcome Wizard..."

    local home_dir
    home_dir=$(getent passwd "${GUI_USER}" 2>/dev/null | cut -d: -f6) || home_dir="/home/${GUI_USER}"
    local config_dir="${home_dir}/.config/calibre"
    local config_file="${config_dir}/global.py"

    execute_cmd "install -d -o '${GUI_USER}' -g '${GUI_USER}' -m 755 '${config_dir}'" \
        "Directorio de configuración GUI"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Escribiría global.py con uuid, language y library_path."
        return 0
    fi

    local uuid
    uuid="$(cat /proc/sys/kernel/random/uuid)"

    if [[ ! -f "${config_file}" ]]; then
        # Primera instalación — crear global.py completo
        local temp_dir
        temp_dir="$(mktemp -d)"
        local candidate="${temp_dir}/global.py"

        cat > "${candidate}" <<EOF
# Generado por Confiraspa — bypass del Welcome Wizard
installation_uuid = '${uuid}'
language = 'es'
library_path = '${LIBRARY_PATH}'
EOF

        execute_cmd "cp '${candidate}' '${config_file}'" "Creando global.py (wizard bypass)"
        execute_cmd "chown '${GUI_USER}:${GUI_USER}' '${config_file}'" "Propietario de global.py"
        execute_cmd "chmod 644 '${config_file}'" "Permisos de global.py"
        rm -rf "${temp_dir}"
        log_success "global.py creado (wizard bypass, biblioteca en ${LIBRARY_PATH})."
    else
        # El fichero existe — añadir solo las claves que falten
        create_backup "${config_file}"

        if ! grep -q "^installation_uuid" "${config_file}"; then
            execute_cmd "bash -c \"echo \\\"installation_uuid = '${uuid}'\\\" >> '${config_file}'\"" \
                "Añadiendo installation_uuid a global.py"
        fi
        if ! grep -q "^library_path" "${config_file}"; then
            execute_cmd "bash -c \"echo \\\"library_path = '${LIBRARY_PATH}'\\\" >> '${config_file}'\"" \
                "Añadiendo library_path a global.py"
        fi
        if ! grep -q "^language" "${config_file}"; then
            execute_cmd "bash -c \"echo \\\"language = 'es'\\\" >> '${config_file}'\"" \
                "Añadiendo language a global.py"
        fi

        execute_cmd "chown '${GUI_USER}:${GUI_USER}' '${config_file}'" "Propietario de global.py"
        log_success "global.py actualizado (wizard bypass)."
    fi
}

# RISK: Elimina server.py que versiones anteriores del script creaban.
# Este fichero no tiene efecto en Calibre (la configuración real está en
# gui.py.json). Eliminarlo evita confusión en diagnósticos futuros.
cleanup_legacy_config() {
    local home_dir
    home_dir=$(getent passwd "${GUI_USER}" 2>/dev/null | cut -d: -f6) || home_dir="/home/${GUI_USER}"
    local legacy_file="${home_dir}/.config/calibre/server.py"

    if [[ -f "${legacy_file}" ]]; then
        execute_cmd "rm -f '${legacy_file}'" "Eliminando server.py legacy (no funcional)"
    fi
}

configure_gui_autostart() {
    log_info "Configurando autostart de Calibre GUI para '${GUI_USER}'..."

    local home_dir
    home_dir=$(getent passwd "${GUI_USER}" 2>/dev/null | cut -d: -f6) || home_dir="/home/${GUI_USER}"

    local apps_dir="${home_dir}/.local/share/applications"
    local autostart_dir="${home_dir}/.config/autostart"

    execute_cmd "install -d -o '${GUI_USER}' -g '${GUI_USER}' -m 755 '${apps_dir}'" \
        "Directorio de aplicaciones"
    execute_cmd "install -d -o '${GUI_USER}' -g '${GUI_USER}' -m 755 '${autostart_dir}'" \
        "Directorio de autostart"

    local exec_line="${CALIBRE_GUI_BINARY} %F"
    if [[ -f /etc/xdg/wayfire.ini ]] || [[ -f /etc/xdg/labwc/rc.xml ]]; then
        exec_line="env QT_QPA_PLATFORM=wayland ${CALIBRE_GUI_BINARY} %F"
        log_info "Wayland detectado — GUI usará QT_QPA_PLATFORM=wayland"
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"
    local candidate="${temp_dir}/calibre-gui.desktop"

    cat > "${candidate}" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Calibre (NAS)
Exec=${exec_line}
Icon=${INSTALL_DIR}/resources/images/calibre.png
Terminal=false
Categories=Office;
Comment=Gestor de biblioteca de eBooks — Content Server en puerto ${CALIBRE_PORT}
EOF

    local desktop_file="${apps_dir}/calibre-gui.desktop"
    local autostart_file="${autostart_dir}/calibre-gui.desktop"

    if [[ -f "${desktop_file}" ]] && cmp -s "${desktop_file}" "${candidate}"; then
        log_info "Archivo .desktop sin cambios."
        rm -rf "${temp_dir}"
        return 0
    fi

    # Backup del .desktop si existía
    if [[ -f "${desktop_file}" ]]; then
        create_backup "${desktop_file}"
    fi

    execute_cmd "cp '${candidate}' '${desktop_file}'" "Instalando .desktop"
    execute_cmd "chown '${GUI_USER}:${GUI_USER}' '${desktop_file}'" "Propietario .desktop"
    execute_cmd "chmod 644 '${desktop_file}'" "Permisos .desktop"
    execute_cmd "cp '${candidate}' '${autostart_file}'" "Configurando autostart"
    execute_cmd "chown '${GUI_USER}:${GUI_USER}' '${autostart_file}'" "Propietario autostart"

    rm -rf "${temp_dir}"
    log_success "Autostart configurado para ${GUI_USER}."
}

post_checks() {
    local ip
    ip="$(get_ip_address)"

    log_success "Calibre configurado (Modelo A — GUI con servidor integrado)."
    log_info "  Biblioteca: ${LIBRARY_PATH}"
    log_info "  GUI:        Autostart en escritorio de ${GUI_USER}"
    log_info "  Web UI:     http://${ip}:${CALIBRE_PORT} (activo cuando la GUI esté abierta)"
    log_info "  El Content Server arranca automáticamente con la GUI de Calibre."
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Instalación de Servidor de eBooks (Calibre)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands install systemctl id getent awk grep uname sed sudo
    validate_env_vars
    validate_architecture

    # --- 2. Dependencias ---
    install_dependencies

    # --- 3. Usuario y grupos ---
    ensure_calibre_user

    # --- 4. Instalación ---
    install_calibre

    # --- 5. Biblioteca ---
    initialize_library

    # --- 6. Deshabilitar servicio standalone legacy ---
    disable_legacy_service

    # --- 7. Limpiar server.py (no funcional) ---
    cleanup_legacy_config

    # --- 8. Bypass del Welcome Wizard (global.py) ---
    preseed_gui_config

    # --- 9. Content Server integrado (gui.py.json) ---
    preseed_server_config

    # --- 10. Autostart GUI ---
    configure_gui_autostart

    # --- 11. Resumen ---
    post_checks
}

main "$@"