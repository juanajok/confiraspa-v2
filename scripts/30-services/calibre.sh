#!/usr/bin/env bash
# scripts/30-services/calibre.sh
# Configuración idempotente de Calibre GUI con Content Server integrado.
#
# MODELO A — GUI con servidor integrado:
#   - Calibre GUI arranca con autostart al iniciar sesión gráfica.
#   - El Content Server se levanta DENTRO de la GUI (server.py: autostart=True).
#   - No hay servicio systemd independiente (evita conflicto SQLite en metadata.db).
#   - El servidor web funciona mientras la sesión gráfica esté activa.
#
# ¿Por qué este modelo? SQLite solo permite un escritor a la vez. Si GUI y
# calibre-server corren simultáneamente, uno falla al guardar. Con el servidor
# integrado, un solo proceso gestiona todo: edición de metadatos + web UI.
#
# Acceso web: http://IP:8083 (mientras la GUI esté abierta)
# Acceso GUI: VNC/XRDP al escritorio del usuario

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

# Servicio standalone que puede existir de una instalación anterior
readonly LEGACY_SERVICE="calibre-server"

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

require_system_commands() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Comando requerido del sistema no disponible: ${cmd}"
            exit 1
        fi
    done
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Verificar arquitectura ---
validate_architecture() {
    local arch
    arch=$(uname -m)

    if [[ "${arch}" != "aarch64" && "${arch}" != "x86_64" ]]; then
        log_error "Arquitectura no soportada: ${arch}. Calibre requiere 64 bits."
        exit 1
    fi
    log_info "Arquitectura: ${arch}"
}

# --- Instalar dependencias Qt/X11 ---
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

# --- Crear usuario de sistema para permisos de la biblioteca ---
# Aunque la GUI corre como GUI_USER, el usuario 'calibre' se usa como
# propietario de la biblioteca para que fix_permissions.sh lo gestione
# de forma consistente con los demás servicios *Arr.
ensure_calibre_user() {
    if id "${CALIBRE_USER}" &>/dev/null; then
        log_info "Usuario '${CALIBRE_USER}' ya existe."
    else
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "[DRY-RUN] Usuario '${CALIBRE_USER}' no existe (normal en simulación)."
            execute_cmd "useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/calibre '${CALIBRE_USER}'" \
                "Creando usuario: ${CALIBRE_USER}"
            return 0
        fi

        execute_cmd "useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/calibre '${CALIBRE_USER}'" \
            "Creando usuario: ${CALIBRE_USER}"
    fi

    # Añadir al grupo multimedia
    if id "${CALIBRE_USER}" &>/dev/null && \
       ! id -nG "${CALIBRE_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx "${MEDIA_GROUP}"; then
        execute_cmd "usermod -aG '${MEDIA_GROUP}' '${CALIBRE_USER}'" \
            "Añadiendo ${CALIBRE_USER} al grupo ${MEDIA_GROUP}"
    fi

    # GUI_USER también necesita pertenecer al grupo media para escribir en la biblioteca
    if id "${GUI_USER}" &>/dev/null && \
       ! id -nG "${GUI_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx "${MEDIA_GROUP}"; then
        execute_cmd "usermod -aG '${MEDIA_GROUP}' '${GUI_USER}'" \
            "Añadiendo ${GUI_USER} al grupo ${MEDIA_GROUP}"
    fi
}

# --- Instalar Calibre desde el instalador oficial ---
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

    local temp_dir
    temp_dir="$(mktemp -d)"
    local installer="${temp_dir}/calibre-installer.sh"

    if ! download_secure "${INSTALLER_URL}" "${installer}"; then
        log_error "Fallo al descargar el instalador de Calibre."
        rm -rf "${temp_dir}"
        exit 1
    fi

    mkdir -p "${BASE_DIR}"

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
        log_error "Binario no encontrado tras la instalación: ${CALIBRE_GUI_BINARY}"
        exit 1
    fi

    log_success "Calibre instalado en ${INSTALL_DIR}."
}

# --- Configurar biblioteca (detectar existente o crear nueva) ---
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
            if "${CALIBREDB_BINARY}" add --with-library "${LIBRARY_PATH}" --empty >> "${LOG_FILE:-/dev/null}" 2>&1; then
                log_success "Biblioteca inicializada."
            else
                log_warning "calibredb no pudo inicializar (normal en primera instalación)."
                log_warning "Se creará automáticamente al abrir Calibre GUI."
            fi
        else
            log_warning "calibredb no disponible. Biblioteca se inicializará al primer uso."
        fi
    fi

    # Propietario del directorio y metadata.db — GUI_USER porque la GUI escribe aquí.
    # Sin -R: fix_permissions.sh cubre el mantenimiento recursivo periódico.
    execute_cmd "chown '${GUI_USER}:${MEDIA_GROUP}' '${LIBRARY_PATH}'" \
        "Propietario de la biblioteca: ${GUI_USER}"

    if [[ -f "${LIBRARY_PATH}/metadata.db" ]]; then
        execute_cmd "chown '${GUI_USER}:${MEDIA_GROUP}' '${LIBRARY_PATH}/metadata.db'" \
            "Propietario de metadata.db: ${GUI_USER}"
    fi
}

# --- Deshabilitar servicio standalone si existe ---
# Si viene de una instalación anterior con Modelo B (systemd), pararlo
# para que no compita con la GUI por metadata.db.
disable_legacy_service() {
    if systemctl is-enabled --quiet "${LEGACY_SERVICE}" 2>/dev/null; then
        log_warning "Servicio standalone '${LEGACY_SERVICE}' detectado. Deshabilitando (Modelo A: GUI integrada)."

        if check_service_active "${LEGACY_SERVICE}"; then
            execute_cmd "systemctl stop '${LEGACY_SERVICE}'" \
                "Deteniendo ${LEGACY_SERVICE}"
        fi

        execute_cmd "systemctl disable '${LEGACY_SERVICE}'" \
            "Deshabilitando ${LEGACY_SERVICE}"

        log_info "El Content Server ahora se gestiona desde la GUI de Calibre."
    fi

    # Eliminar unit file si existe (limpieza)
    local service_file="/etc/systemd/system/${LEGACY_SERVICE}.service"
    if [[ -f "${service_file}" ]]; then
        execute_cmd "rm -f '${service_file}'" \
            "Eliminando unit file legacy: ${service_file}"
        execute_cmd "systemctl daemon-reload" "Recargando systemd"
    fi
}

# --- Pre-configurar Content Server dentro de la GUI ---
# Escribe server.py para que al abrir Calibre GUI, levante el Content Server
# automáticamente en el puerto configurado. Así un solo proceso (la GUI)
# gestiona metadata.db sin conflictos de bloqueo SQLite.
preseed_server_config() {
    local home_dir
    home_dir=$(getent passwd "${GUI_USER}" 2>/dev/null | cut -d: -f6) || home_dir="/home/${GUI_USER}"
    local config_dir="${home_dir}/.config/calibre"
    local server_config="${config_dir}/server.py"

    # Contenido esperado
    local expected_content
    expected_content=$(cat <<EOF
# Generado por Confiraspa — Content Server integrado en GUI
autostart = True
port = ${CALIBRE_PORT}
EOF
    )

    # Idempotencia: si ya tiene el contenido correcto, no tocar
    if [[ -f "${server_config}" ]] && \
       grep -q "autostart = True" "${server_config}" && \
       grep -q "port = ${CALIBRE_PORT}" "${server_config}"; then
        log_info "Content Server ya configurado en GUI (puerto ${CALIBRE_PORT})."
        return 0
    fi

    execute_cmd "install -d -o '${GUI_USER}' -g '${GUI_USER}' -m 755 '${config_dir}'" \
        "Directorio de configuración Calibre"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Escribiría server.py con autostart=True, port=${CALIBRE_PORT}"
        return 0
    fi

    echo "${expected_content}" > "${server_config}"
    chown "${GUI_USER}:${GUI_USER}" "${server_config}"
    chmod 644 "${server_config}"

    log_success "Content Server integrado configurado: autostart en puerto ${CALIBRE_PORT}."
}

# --- Pre-configurar ruta de la biblioteca en la GUI ---
# Evita el wizard de primera ejecución que pregunta dónde están los libros.
preseed_gui_config() {
    local home_dir
    home_dir=$(getent passwd "${GUI_USER}" 2>/dev/null | cut -d: -f6) || home_dir="/home/${GUI_USER}"
    local config_dir="${home_dir}/.config/calibre"
    local config_file="${config_dir}/global.py"

    local expected_line="library_path = u'${LIBRARY_PATH}'"

    if [[ -f "${config_file}" ]] && grep -qF "${expected_line}" "${config_file}"; then
        log_info "GUI ya apunta a ${LIBRARY_PATH}."
        return 0
    fi

    execute_cmd "install -d -o '${GUI_USER}' -g '${GUI_USER}' -m 755 '${config_dir}'" \
        "Directorio de configuración GUI"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Escribiría ruta de biblioteca en global.py"
        return 0
    fi

    echo "${expected_line}" > "${config_file}"
    chown "${GUI_USER}:${GUI_USER}" "${config_file}"
    chmod 644 "${config_file}"

    log_success "GUI pre-configurada: biblioteca en ${LIBRARY_PATH}"
}

# --- Configurar autostart GUI en el escritorio ---
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

    # Detectar backend gráfico para Qt
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

    execute_cmd "cp '${candidate}' '${desktop_file}'" "Instalando .desktop"
    execute_cmd "chown '${GUI_USER}:${GUI_USER}' '${desktop_file}'" "Propietario .desktop"
    execute_cmd "chmod 644 '${desktop_file}'" "Permisos .desktop"

    execute_cmd "cp '${candidate}' '${autostart_file}'" "Configurando autostart"
    execute_cmd "chown '${GUI_USER}:${GUI_USER}' '${autostart_file}'" "Propietario autostart"

    rm -rf "${temp_dir}"

    log_success "Autostart configurado para ${GUI_USER}."
}

# --- Post-checks ---
post_checks() {
    local ip
    ip="$(get_ip_address)"

    log_success "Calibre configurado (Modelo A — GUI con servidor integrado)."
    log_info "  Biblioteca: ${LIBRARY_PATH}"
    log_info "  GUI:        Autostart en escritorio de ${GUI_USER}"
    log_info "  Web UI:     http://${ip}:${CALIBRE_PORT} (activo cuando la GUI esté abierta)"
    log_info ""
    log_info "  El Content Server arranca automáticamente con la GUI de Calibre."
    log_info "  Para acceso web 24/7 sin GUI, cambiar a Modelo B (systemd standalone)."
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
    require_system_commands install systemctl id getent awk grep uname
    validate_architecture

    # --- 2. Dependencias ---
    install_dependencies

    # --- 3. Usuario y grupos ---
    ensure_calibre_user

    # --- 4. Instalación de Calibre ---
    install_calibre

    # --- 5. Biblioteca (detectar existente o crear nueva) ---
    initialize_library

    # --- 6. Deshabilitar servicio standalone (si existe de instalación anterior) ---
    disable_legacy_service

    # --- 7. Content Server integrado en GUI (server.py) ---
    preseed_server_config

    # --- 8. Ruta de biblioteca en GUI (global.py) ---
    preseed_gui_config

    # --- 9. Autostart GUI ---
    configure_gui_autostart

    # --- 10. Resumen ---
    post_checks
}

main "$@"