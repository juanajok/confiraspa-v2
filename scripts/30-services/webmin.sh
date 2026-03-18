#!/usr/bin/env bash
# scripts/30-services/webmin.sh
# Configuración idempotente de Webmin (Panel de Administración) para Confiraspa.
#
# Webmin usa un repositorio APT con firma GPG basada en SHA-1 (jcameron-key.asc).
# Desde febrero de 2026, Debian/RPi OS rechaza SHA-1 a nivel de sqv (el backend
# PGP de Sequoia). La opción signed-by + allow-weak=yes no llega a sqv, por lo que
# usamos trusted=yes scoped exclusivamente a este repositorio. La seguridad del
# transporte descansa en HTTPS. Cuando Webmin actualice su firma, basta con
# restaurar signed-by y eliminar trusted=yes.

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
readonly SERVICE_NAME="webmin"
readonly WEBMIN_PORT="10000"
readonly REPO_URL="https://download.webmin.com/download/repository"
readonly KEY_URL="https://download.webmin.com/jcameron-key.asc"
readonly WEBMIN_KEYRING="/usr/share/keyrings/webmin.gpg"
readonly WEBMIN_REPO_FILE="/etc/apt/sources.list.d/webmin.list"

# trusted=yes: bypass de verificación GPG scoped a este repo únicamente.
# Ver comentario de cabecera para justificación completa.
readonly WEBMIN_REPO_LINE="deb [trusted=yes] ${REPO_URL} sarge contrib"

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

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Instalar dependencias Perl que Webmin necesita para compilar módulos ---
# Instalarlas antes del paquete principal acelera el proceso y evita
# errores de dependencias durante la instalación de Webmin.
install_perl_dependencies() {
    log_info "Pre-instalando dependencias de Perl..."
    local dep
    for dep in perl libnet-ssleay-perl openssl libauthen-pam-perl \
               libpam-runtime libio-pty-perl python3; do
        ensure_package "${dep}"
    done
}

# --- Configurar repositorio APT de Webmin ---
# Idempotente: si el .list ya existe, no toca nada.
# Auto-limpieza: si apt-get update falla tras añadir el repo, elimina
# tanto el .list como el keyring para que el script sea re-ejecutable.
install_webmin_repo() {
    if [[ -f "${WEBMIN_REPO_FILE}" ]]; then
        log_info "Repositorio Webmin ya configurado."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Configuraría repositorio Webmin (trusted=yes)."
        return 0
    fi

    log_info "Configurando repositorio oficial de Webmin..."
    log_warning "Firma GPG omitida (trusted=yes): infraestructura SHA-1 deprecada en 2026."

    # Descarga de llave GPG — aunque usamos trusted=yes, conservamos el keyring
    # para restaurar signed-by cuando Webmin actualice su firma.
    local tmp_key
    tmp_key="$(mktemp)"

    if ! download_secure "${KEY_URL}" "${tmp_key}"; then
        log_error "Fallo al descargar la llave GPG de Webmin."
        rm -f "${tmp_key}"
        exit 1
    fi

    gpg --dearmor < "${tmp_key}" > "${WEBMIN_KEYRING}" 2>/dev/null
    rm -f "${tmp_key}"

    if [[ ! -s "${WEBMIN_KEYRING}" ]]; then
        log_error "El keyring GPG de Webmin se generó vacío. Verifica la conectividad."
        rm -f "${WEBMIN_KEYRING}"
        exit 1
    fi
    chmod 644 "${WEBMIN_KEYRING}"

    # Escribir la fuente APT
    echo "${WEBMIN_REPO_LINE}" > "${WEBMIN_REPO_FILE}"

    # Validar que apt-get update funciona con el nuevo repo
    if ! apt-get update -qq; then
        log_error "apt-get update falló tras añadir el repositorio de Webmin. Limpiando..."
        rm -f "${WEBMIN_REPO_FILE}" "${WEBMIN_KEYRING}"
        exit 1
    fi

    log_success "Repositorio Webmin configurado y validado."
}

# --- Instalar paquete Webmin (idempotente) ---
install_webmin_package() {
    # dpkg-query es más fiable que dpkg -l | grep para detectar instalación
    if dpkg-query -W -f='${Status}' webmin 2>/dev/null | grep -q "install ok installed"; then
        log_info "Webmin ya está instalado."
        return 0
    fi

    # Webmin es grande (~70MB) y trae muchos módulos Perl.
    # --no-install-recommends evita dependencias opcionales innecesarias en RPi.
    log_info "Instalando paquete Webmin (puede tardar unos minutos)..."
    execute_cmd "apt-get install -y --no-install-recommends webmin" \
        "Instalación de Webmin"
}

# --- Arrancar y verificar servicio ---
start_and_verify() {
    execute_cmd "systemctl daemon-reload" "Recargando systemd"
    execute_cmd "systemctl enable '${SERVICE_NAME}'" "Habilitando ${SERVICE_NAME}"

    # Restart necesario tras instalación para aplicar config SSL y puertos
    execute_cmd "systemctl restart '${SERVICE_NAME}'" "Reiniciando ${SERVICE_NAME}"
}

# --- Comprobaciones post-instalación ---
post_checks() {
    # Webmin tarda unos segundos en generar su certificado SSL autofirmado
    # en el primer arranque. 30s cubre RPi con SD lenta.
    if ! wait_for_service "localhost" "${WEBMIN_PORT}" "Webmin" 30; then
        log_error "Webmin no responde en el puerto ${WEBMIN_PORT}."
        log_error "Diagnóstico: journalctl -u ${SERVICE_NAME} -n 50"
        log_error "Config:      /etc/webmin/miniserv.conf"
        exit 1
    fi

    local ip
    ip="$(get_ip_address)"

    log_success "Webmin instalado y operativo."
    log_info "  Panel:      https://${ip}:${WEBMIN_PORT}"
    log_info "  Usuario:    ${SYS_USER:-root} (tu usuario de sistema)"
    log_info "  Contraseña: tu contraseña de sistema"
    log_info "  Nota:       Usa HTTPS. Acepta el certificado autofirmado."
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Instalación de Panel de Administración (Webmin)"

    # --- 1. Validaciones previas ---
    validate_root
    require_system_commands curl gpg systemctl dpkg-query awk

    # --- 2. Dependencias Perl (antes del repo para acelerar instalación) ---
    ensure_package "apt-transport-https"
    install_perl_dependencies

    # --- 3. Repositorio APT ---
    install_webmin_repo

    # --- 4. Instalación del paquete ---
    install_webmin_package

    # --- 5. Arranque ---
    start_and_verify

    # --- 6. Verificación ---
    post_checks
}

main "$@"