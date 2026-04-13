#!/usr/bin/env bash
# scripts/00-system/00-update.sh
# Actualización del sistema y configuración de parches de seguridad automáticos.
#
# Dos responsabilidades:
#   1. Actualización inmediata: apt update + upgrade + dist-upgrade + limpieza.
#   2. Configuración de unattended-upgrades: parches de seguridad diarios
#      automáticos sin intervención manual ni reinicios.
#
# Diseñado para ejecutarse desde install.sh y desde cron (diariamente 06:00 AM).
# En ejecución desde cron, solo aplica la actualización inmediata (paso 1).
# La configuración de unattended-upgrades (paso 2) es idempotente y solo
# modifica ficheros si el contenido ha cambiado.

set -euo pipefail
IFS=$'\n\t'

# Cron ejecuta con PATH mínimo. Asegurar rutas estándar.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Evitar que apt pregunte "¿Quiere sobrescribir el archivo de config?"
export DEBIAN_FRONTEND=noninteractive

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

# Cargar .env si no estamos bajo install.sh
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# LOG_FILE para ejecución desde cron
if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="/var/log/auto_update.log"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================

# Opciones de apt para modo no interactivo:
#   --force-confdef: usa la config por defecto si hay conflicto
#   --force-confold: conserva la config del usuario si fue modificada
readonly APT_OPTS="-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

readonly UNATTENDED_CONF="/etc/apt/apt.conf.d/52confiraspa-unattended"
readonly PERIODIC_CONF="/etc/apt/apt.conf.d/20auto-upgrades"

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

# --- Actualización inmediata del sistema ---
run_system_update() {
    log_info "Actualizando repositorios y paquetes del sistema..."

    execute_cmd "apt-get update -qq" "Actualizando lista de paquetes"
    execute_cmd "apt-get upgrade ${APT_OPTS}" "Aplicando actualizaciones pendientes"
    execute_cmd "apt-get dist-upgrade ${APT_OPTS}" "Aplicando actualizaciones de distribución"
    execute_cmd "apt-get autoremove -y" "Eliminando dependencias huérfanas"
    execute_cmd "apt-get clean" "Limpiando caché de apt"

    log_success "Sistema actualizado."
}

# --- Configurar orígenes de unattended-upgrades ---
# Genera 52confiraspa-unattended con los orígenes de seguridad permitidos.
# Usa candidato + cmp para idempotencia (no sobreescribe si no ha cambiado).
configure_unattended_origins() {
    log_info "Configurando orígenes de unattended-upgrades..."

    local temp_dir
    temp_dir="$(mktemp -d)"
    local candidate="${temp_dir}/52confiraspa-unattended"

    # Detectar versión de Debian para la config
    local distro_codename
    distro_codename=$(lsb_release -sc 2>/dev/null) || distro_codename="bookworm"

    cat > "${candidate}" <<'EOF'
// Configuración gestionada por Confiraspa
// Sobrescribe valores por defecto de unattended-upgrades.

Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "Raspbian:${distro_codename}";
    "Raspberry Pi Foundation:${distro_codename}";
};

Unattended-Upgrade::Package-Blacklist {
};

// Opciones de comportamiento
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

    # Idempotencia: solo instalar si ha cambiado
    if [[ -f "${UNATTENDED_CONF}" ]] && cmp -s "${UNATTENDED_CONF}" "${candidate}"; then
        log_info "Configuración de orígenes sin cambios."
        rm -rf "${temp_dir}"
        return 0
    fi

    if [[ -f "${UNATTENDED_CONF}" ]]; then
        create_backup "${UNATTENDED_CONF}"
    fi

    execute_cmd "cp '${candidate}' '${UNATTENDED_CONF}'" \
        "Instalando configuración de orígenes: ${UNATTENDED_CONF}"

    rm -rf "${temp_dir}"
}

# --- Configurar periodicidad de actualizaciones automáticas ---
configure_periodic() {
    log_info "Configurando frecuencia de actualizaciones automáticas..."

    local temp_dir
    temp_dir="$(mktemp -d)"
    local candidate="${temp_dir}/20auto-upgrades"

    cat > "${candidate}" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

    if [[ -f "${PERIODIC_CONF}" ]] && cmp -s "${PERIODIC_CONF}" "${candidate}"; then
        log_info "Configuración de periodicidad sin cambios."
        rm -rf "${temp_dir}"
        return 0
    fi

    if [[ -f "${PERIODIC_CONF}" ]]; then
        create_backup "${PERIODIC_CONF}"
    fi

    execute_cmd "cp '${candidate}' '${PERIODIC_CONF}'" \
        "Instalando configuración de periodicidad: ${PERIODIC_CONF}"

    rm -rf "${temp_dir}"
}

# --- Verificar que la configuración es válida ---
verify_unattended() {
    log_info "Verificando configuración de unattended-upgrades..."

    if run_check "unattended-upgrade --dry-run --debug" "Test de unattended-upgrades"; then
        log_success "Actualizaciones automáticas configuradas correctamente."
    else
        log_warning "El test de unattended-upgrades reportó problemas."
        log_warning "Revisa: journalctl -u unattended-upgrades o los logs en /var/log/unattended-upgrades/"
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Actualización del Sistema y Parches de Seguridad"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands apt-get

    # --- 2. Actualización inmediata ---
    run_system_update

    # --- 3. Configurar actualizaciones automáticas de seguridad ---
    ensure_package "unattended-upgrades"
    ensure_package "apt-listchanges"

    configure_unattended_origins
    configure_periodic

    # --- 4. Verificación ---
    verify_unattended
}

main "$@"