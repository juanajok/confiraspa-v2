#!/usr/bin/env bash
# scripts/30-services/samba.sh
# Configuración robusta de Samba (Confiraspa V2)
# Debian 13 + Raspberry Pi 5 + NTFS/EXT4 + AppArmor Fix

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

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly TARGET_CONF="/etc/samba/smb.conf"

readonly SAMBA_USER="${SMB_USER:-${SYS_USER:-pi}}"
readonly SAMBA_GROUP="${ARR_GROUP:-media}"
readonly SAMBA_WORKGROUP="${SMB_WORKGROUP:-WORKGROUP}"

readonly SHARE_LIBRARY="${PATH_LIBRARY:-/media/WDElements}"
readonly SHARE_DOWNLOADS="${DIR_TORRENTS:-/media/DiscoDuro/torrents/completos}"
readonly SHARE_BACKUP="${PATH_BACKUP:-/media/Backup}"

readonly SHARE_NAME_LIBRARY="${SMB_SHARE_LIBRARY:-$(basename "${SHARE_LIBRARY}")}"
readonly SHARE_NAME_DOWNLOADS="${SMB_SHARE_DOWNLOADS:-Descargas}"
readonly SHARE_NAME_BACKUP="${SMB_SHARE_BACKUP:-$(basename "${SHARE_BACKUP}")}"

# ===========================================================================
# FUNCIONES
# ===========================================================================

on_error() {
    local exit_code="${1:-1}"
    log_error "Error en Samba (línea ${BASH_LINENO[0]}, exit ${exit_code})"
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

render_samba_config() {
    local output_file="$1"

    cat > "${output_file}" <<EOF
# Confiraspa NAS — Configuración estable y compatible (V2)

[global]
   workgroup = ${SAMBA_WORKGROUP}
   server string = Confiraspa NAS
   netbios name = %h

   security = user
   map to guest = Bad User
   guest account = nobody

   server min protocol = SMB2
   restrict anonymous = 2

   # Rendimiento RPi 5
   use sendfile = yes
   aio read size = 1
   aio write size = 1
   getwd cache = yes

   # Logging
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

[${SHARE_NAME_LIBRARY}]
   path = ${SHARE_LIBRARY}
   browseable = yes
   read only = no
   guest ok = yes
   force user = ${SAMBA_USER}
   force group = ${SAMBA_GROUP}
   create mask = 0664
   directory mask = 2775
   inherit permissions = yes
   vfs objects = recycle
   recycle:repository = .recycle/%U
   recycle:keeptree = yes
   recycle:versions = yes
   recycle:touch = yes

[${SHARE_NAME_DOWNLOADS}]
   path = ${SHARE_DOWNLOADS}
   browseable = yes
   read only = no
   guest ok = yes
   force user = ${SAMBA_USER}
   force group = ${SAMBA_GROUP}
   create mask = 0664
   directory mask = 2775
   inherit permissions = yes
   vfs objects = recycle
   recycle:repository = .recycle/%U
   recycle:keeptree = yes

[${SHARE_NAME_BACKUP}]
   path = ${SHARE_BACKUP}
   browseable = yes
   read only = no
   guest ok = yes
   force user = ${SAMBA_USER}
   force group = ${SAMBA_GROUP}
   create mask = 0664
   directory mask = 2775
EOF
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    local temp_dir=""
    trap 'rm -rf "${temp_dir:-}"' EXIT
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Configuración Samba (NAS Profesional)"

    validate_root
    require_system_commands systemctl mktemp cp cmp chmod chown testparm

    # 1. Paquetes necesarios
    ensure_package "samba"
    ensure_package "samba-vfs-modules"
    ensure_package "apparmor-utils"

    # 2. AppArmor → evitar bloqueo de /media
    if [[ "${DRY_RUN}" == "false" ]]; then
        execute_cmd "aa-complain /usr/sbin/smbd" \
            "Desbloqueando AppArmor para Samba"
    fi

    # 3. Permisos mínimos (SIN recursividad)
    execute_cmd "chmod 755 /media" \
        "Permitir traversal en /media"

    for dir in "${SHARE_LIBRARY}" "${SHARE_DOWNLOADS}" "${SHARE_BACKUP}"; do
        [[ -z "${dir}" ]] && continue

        if [[ -d "${dir}" ]]; then
            execute_cmd "chown ${SAMBA_USER}:${SAMBA_GROUP} '${dir}'" \
                "Owner punto de montaje: ${dir##*/}"

            execute_cmd "chmod 775 '${dir}'" \
                "Permisos punto de montaje: ${dir##*/}"
        else
            log_warning "Ruta no encontrada: ${dir}"
        fi
    done

    # 4. Generar configuración
    temp_dir="$(mktemp -d)"
    local candidate="${temp_dir}/smb.conf"

    render_samba_config "${candidate}"

    if [[ -f "${TARGET_CONF}" ]] && cmp -s "${TARGET_CONF}" "${candidate}"; then
        log_info "Configuración ya aplicada. Nada que hacer."
    else
        if [[ "${DRY_RUN}" == "false" ]]; then

            # VALIDACIÓN CRÍTICA
            if ! testparm -s "${candidate}" >/dev/null 2>&1; then
                log_error "smb.conf inválido. Abortando despliegue."
                exit 1
            fi

            [[ -f "${TARGET_CONF}" ]] && create_backup "${TARGET_CONF}"

            execute_cmd "cp '${candidate}' '${TARGET_CONF}'" \
                "Instalando smb.conf"

            execute_cmd "chmod 644 '${TARGET_CONF}'" \
                "Protegiendo smb.conf"

            execute_cmd "systemctl restart smbd" \
                "Reiniciando Samba"
        else
            log_info "[DRY-RUN] Se aplicaría smb.conf validado."
        fi
    fi

    # 5. Verificación final
    if [[ "${DRY_RUN}" == "false" ]]; then
        if check_service_active "smbd"; then
            log_success "Samba operativo ✅"
            log_info "Tip Windows: net use * /delete /y"
        else
            log_error "Samba no arrancó. Revisar /var/log/samba/"
            exit 1
        fi
    fi
}

main "$@"