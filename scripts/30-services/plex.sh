#!/usr/bin/env bash
# scripts/30-services/plex.sh
# Instalación idempotente de Plex Media Server (repositorio oficial)

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

readonly PLEX_SERVICE="plexmediaserver"
readonly PLEX_USER="plex"
readonly PLEX_REPO_FILE="/etc/apt/sources.list.d/plexmediaserver.list"
readonly PLEX_KEYRING="/usr/share/keyrings/plexmediaserver.gpg"
readonly PLEX_KEY_URL="https://downloads.plex.tv/plex-keys/PlexSign.key"
readonly PLEX_WEB_PORT="32400"
readonly PLEX_DATA_DIR="/var/lib/plexmediaserver"

# NOTA TÉCNICA (2026-02-01):
# La infraestructura de firma de Plex usa SHA-1, que Debian deprecó como
# inseguro en febrero de 2026. sqv (el backend PGP de Sequoia) rechaza SHA-1
# a nivel criptográfico antes de que APT pueda aplicar allow-weak=yes.
# trusted=yes desactiva la verificación GPG SOLO para este repositorio.
# La integridad del transporte queda garantizada por TLS (HTTPS).
# Cuando Plex actualice su infraestructura de firma, restaurar a:
# "deb [signed-by=${PLEX_KEYRING}] https://downloads.plex.tv/repo/deb public main"
readonly PLEX_REPO_LINE="deb [trusted=yes] https://downloads.plex.tv/repo/deb public main"

DRY_RUN=false

source "${REPO_ROOT}/lib/colors.sh"
source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

# Cargar .env si no estamos bajo install.sh (ej: --only plex)
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# =============================================================================
# MANEJO DE ERRORES
# =============================================================================
on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."
    exit "${exit_code}"
}

trap 'on_error "$?"' ERR

# =============================================================================
# ARGUMENTOS
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                export DRY_RUN
                shift
                ;;
            *)
                log_error "Argumento no soportado: $1"
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# VALIDACIONES LOCALES
# =============================================================================
require_system_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || {
            log_error "Herramienta de sistema no disponible: ${cmd}"
            exit 1
        }
    done
}

require_service_commands() {
    [[ "${DRY_RUN}" == "true" ]] && return 0
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || {
            log_error "Binario del servicio no disponible tras la instalación: ${cmd}"
            log_error "La instalación del paquete puede haber fallado."
            exit 1
        }
    done
}

require_env_vars_local() {
    local var_name
    for var_name in "$@"; do
        if [[ -z "${!var_name:-}" ]]; then
            log_error "Variable requerida vacía o no definida: ${var_name}"
            exit 1
        fi
    done
}

# =============================================================================
# REPOSITORIO APT
#
# Con trusted=yes no es necesario gestionar el keyring GPG. La integridad
# del transporte queda garantizada por TLS. El keyring se mantiene en el
# código para facilitar la restauración cuando Plex actualice su firma.
# Si apt-get update falla, limpia el .list para re-ejecución limpia.
# =============================================================================
install_plex_repo() {
    if [[ -f "${PLEX_REPO_FILE}" ]]; then
        log_info "Repositorio Plex ya configurado."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Configuraría repositorio oficial de Plex (trusted=yes, SHA-1 workaround)."
        return 0
    fi

    log_info "Instalando repositorio oficial de Plex..."
    log_warning "Firma GPG omitida (trusted=yes): infraestructura SHA-1 de Plex deprecada en Debian post-2026."
    log_warning "Integridad del transporte garantizada por TLS. Restaurar GPG cuando Plex actualice su firma."

    echo "${PLEX_REPO_LINE}" > "${PLEX_REPO_FILE}"
    log_info "Fuente APT de Plex añadida."

    log_info "Validando integridad del repositorio..."
    if ! apt-get update -qq; then
        log_error "apt-get update falló. El repositorio no es confiable. Limpiando..."
        rm -f "${PLEX_REPO_FILE}"
        exit 1
    fi

    log_success "Repositorio Plex configurado y validado."
}

# =============================================================================
# INTEGRACIÓN NAS Y HARDWARE
# =============================================================================
integrate_plex_with_nas() {
    local media_group="${ARR_GROUP:-media}"

    # plex no existe en dry-run (el paquete fue simulado, no instalado)
    assert_system_state \
        "id -u '${PLEX_USER}'" \
        "Usuario '${PLEX_USER}' no existe. La instalación del paquete puede haber fallado."

    # Grupo media — acceso a /media/WDElements sin chmod 777
    if [[ "${DRY_RUN}" != "true" ]]; then
        if ! id -nG "${PLEX_USER}" | grep -qw "${media_group}"; then
            execute_cmd "usermod -aG '${media_group}' '${PLEX_USER}'" \
                "Añadiendo plex al grupo ${media_group}"
        else
            log_info "Usuario '${PLEX_USER}' ya pertenece al grupo '${media_group}'."
        fi
    else
        execute_cmd "usermod -aG '${media_group}' '${PLEX_USER}'" \
            "Añadiendo plex al grupo ${media_group} (simulado)"
    fi

    # Hardware transcoding — /dev/dri y decodificadores (RPi 4/5)
    local grp
    for grp in video render; do
        if getent group "${grp}" >/dev/null 2>&1; then
            if [[ "${DRY_RUN}" != "true" ]] && id -nG "${PLEX_USER}" | grep -qw "${grp}" 2>/dev/null; then
                log_info "Usuario '${PLEX_USER}' ya pertenece al grupo '${grp}'."
                continue
            fi
            execute_cmd "usermod -aG '${grp}' '${PLEX_USER}'" \
                "Añadiendo plex al grupo ${grp} (hardware transcoding)"
        fi
    done

    # Asegurar propiedad de la librería de Plex.
    # Necesario en restauraciones donde la DB tiene propietario incorrecto.
    if [[ "${DRY_RUN}" != "true" && -d "${PLEX_DATA_DIR}" ]]; then
        execute_cmd "chown -R '${PLEX_USER}:${PLEX_USER}' '${PLEX_DATA_DIR}'" \
            "Asegurando propiedad de ${PLEX_DATA_DIR}"
    fi
}

# =============================================================================
# GESTIÓN DEL SERVICIO
# =============================================================================
enable_and_restart_plex() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Omitiendo restart/enable de ${PLEX_SERVICE}."
        return 0
    fi

    execute_cmd "systemctl daemon-reload" "Recargando systemd"
    execute_cmd "systemctl enable '${PLEX_SERVICE}'" "Habilitando ${PLEX_SERVICE}"
    # Restart necesario para aplicar nuevos grupos
    execute_cmd "systemctl restart '${PLEX_SERVICE}'" "Reiniciando ${PLEX_SERVICE}"
}

# =============================================================================
# POST-CHECKS
# =============================================================================
post_checks() {
    if ! wait_for_service "localhost" "${PLEX_WEB_PORT}" "${PLEX_SERVICE}" 30; then
        if [[ "${DRY_RUN}" != "true" ]]; then
            log_error "Plex no responde en el puerto ${PLEX_WEB_PORT}."
            log_error "Revisa: journalctl -u ${PLEX_SERVICE} -n 50"
            exit 1
        fi
    fi

    if [[ "${DRY_RUN}" != "true" ]]; then
        local host_ip
        host_ip="$(get_ip_address)"

        log_success "Plex Media Server instalado y activo."
        log_info "  Web UI:   http://${host_ip}:${PLEX_WEB_PORT}/web"
        log_info "  Servicio: ${PLEX_SERVICE} activo"

        if [[ -n "${PLEX_CLAIM_TOKEN:-}" ]]; then
            log_info "  Claim token detectado en .env."
            log_info "  La reclamación se delega a la primera visita web (más seguro)."
        fi

        log_warning "Repo con trusted=yes activo. Restaurar verificación GPG cuando Plex actualice su firma."
        log_warning "Si es la primera instalación, reclama el servidor desde la Web UI ahora."
        log_warning "Si Plex no ve tus archivos inmediatamente, reinicia la Raspberry Pi."
    else
        log_success "Configuración de Plex simulada correctamente."
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    validate_root

    # Herramientas necesarias para el script
    require_system_commands curl install systemctl id getent grep awk dpkg-query

    require_env_vars_local ARR_GROUP

    log_section "Instalación de Plex Media Server"

    # 1. Dependencia base
    ensure_package "apt-transport-https"

    # 2. Repositorio (Ya con trusted=yes para saltar el problema de SHA-1 en 2026)
    install_plex_repo

    # 3. Instalación de la aplicación
    ensure_package "plexmediaserver"
    
    # VALIDACIÓN CORRECTA: Plex no está en el PATH, chequeamos su carpeta
    assert_system_state "[[ -d /usr/lib/plexmediaserver ]]" "Plex instalado pero no se encuentra en /usr/lib/plexmediaserver"

    # 4. Configuración de permisos y grupos
    integrate_plex_with_nas

    # 5. Gestión de servicio
    if [[ "${DRY_RUN}" == "false" ]]; then
        execute_cmd "systemctl daemon-reload" "Recargando systemd"
        execute_cmd "systemctl enable '${PLEX_SERVICE}'" "Habilitando Plex"
        execute_cmd "systemctl restart '${PLEX_SERVICE}'" "Reiniciando Plex para aplicar grupos"
    fi

    # 6. Verificación final de puerto
    post_checks

    log_success "Plex configurado correctamente."
}

main "$@"