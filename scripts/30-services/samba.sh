#!/usr/bin/env bash
# scripts/30-services/samba.sh
# Configuración idempotente de Samba como NAS doméstico para Confiraspa.
#
# Modo de acceso: público (guest ok = yes). Los clientes acceden sin
# contraseña. Todos los ficheros se crean como SAMBA_USER:MEDIA_GROUP
# con permisos 664/2775 (SetGID para herencia de grupo).
#
# VFS stack por share:
#   - recycle: papelera de reciclaje por usuario (recuperación de borrados)
#   - full_audit: auditoría de operaciones en syslog (LOCAL7)
#   - streams_xattr: soporte de streams NTFS (necesario para macOS/Windows)
#
# Shares:
#   [WDElements]  → Biblioteca multimedia (Series, Películas, Música, Libros)
#   [Descargas]   → Torrents completados
#   [Backup]      → Copias de seguridad

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
readonly TARGET_CONF="/etc/samba/smb.conf"
readonly SAMBA_USER="${SMB_USER:-${SYS_USER:-pi}}"
readonly SAMBA_GROUP="${ARR_GROUP:-media}"
readonly SAMBA_WORKGROUP="${SMB_WORKGROUP:-WORKGROUP}"

# Rutas de los shares — del .env
readonly SHARE_LIBRARY="${PATH_LIBRARY:-/media/WDElements}"
readonly SHARE_BACKUP="${PATH_BACKUP:-/media/Backup}"
readonly SHARE_DOWNLOADS="${DIR_TORRENTS:-/media/DiscoDuro/torrents/completos}"

# Nombres de los shares (lo que ven los clientes en el explorador de red).
# Defaults: basename de la ruta para Library y Backup, "Descargas" para torrents.
readonly SHARE_NAME_LIBRARY="${SMB_SHARE_LIBRARY:-$(basename "${SHARE_LIBRARY}")}"
readonly SHARE_NAME_DOWNLOADS="${SMB_SHARE_DOWNLOADS:-Descargas}"
readonly SHARE_NAME_BACKUP="${SMB_SHARE_BACKUP:-$(basename "${SHARE_BACKUP}")}"

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

validate_env_vars() {
    validate_var "SYS_USER" "${SYS_USER:-}"
    validate_var "ARR_GROUP" "${ARR_GROUP:-}"
    validate_var "PATH_LIBRARY" "${PATH_LIBRARY:-}"
    validate_var "PATH_BACKUP" "${PATH_BACKUP:-}"
}

# --- Generar smb.conf en un fichero candidato ---
render_samba_config() {
    local output_file="$1"

    cat > "${output_file}" <<EOF
# Generado por Confiraspa — NAS doméstico con papelera de reciclaje
[global]
   workgroup = ${SAMBA_WORKGROUP}
   server string = Confiraspa NAS @ %h
   netbios name = %h
   security = user
   map to guest = Bad User
   guest account = nobody

   # Protocolo mínimo SMB2 (desactiva SMB1, inseguro)
   # SECURITY: SMB1 tiene vulnerabilidades conocidas (EternalBlue, WannaCry)
   server min protocol = SMB2

   # Rendimiento para RPi con discos USB
   use sendfile = yes
   aio read size = 1
   aio write size = 1
   getwd cache = yes

   # Logging
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

   # Soporte de streams NTFS (necesario para compatibilidad macOS/Windows)
   vfs objects = streams_xattr

[${SHARE_NAME_LIBRARY}]
   comment = Biblioteca Multimedia
   path = ${SHARE_LIBRARY}
   browseable = yes
   read only = no
   guest ok = yes
   force user = ${SAMBA_USER}
   force group = ${SAMBA_GROUP}
   create mask = 0664
   directory mask = 2775
   inherit permissions = yes
   inherit acls = yes
   # VFS stack: papelera + auditoría + streams NTFS
   vfs objects = recycle full_audit streams_xattr
   # Papelera: ficheros borrados van a .recycle/<usuario>
   recycle:repository = .recycle/%U
   recycle:keeptree = yes
   recycle:versions = yes
   recycle:exclude = *.tmp,*.temp,*.obj,~\$*,*.part,*.!qb,.DS_Store,Thumbs.db
   # Auditoría: operaciones relevantes a syslog (LOCAL7)
   full_audit:prefix = %u|%I|%m|%S
   full_audit:success = connect disconnect unlink rmdir rename mkdir
   full_audit:failure = none
   full_audit:facility = LOCAL7
   full_audit:priority = NOTICE

[${SHARE_NAME_DOWNLOADS}]
   comment = Torrents Completados
   path = ${SHARE_DOWNLOADS}
   browseable = yes
   read only = no
   guest ok = yes
   force user = ${SAMBA_USER}
   force group = ${SAMBA_GROUP}
   create mask = 0664
   directory mask = 2775
   inherit permissions = yes
   inherit acls = yes
   vfs objects = recycle full_audit streams_xattr
   recycle:repository = .recycle/%U
   recycle:keeptree = yes
   recycle:exclude = *.tmp,*.temp,*.obj,~\$*,*.part,*.!qb,.DS_Store,Thumbs.db
   full_audit:prefix = %u|%I|%m|%S
   full_audit:success = connect disconnect unlink rmdir rename mkdir
   full_audit:failure = none
   full_audit:facility = LOCAL7
   full_audit:priority = NOTICE

[${SHARE_NAME_BACKUP}]
   comment = Copias de Seguridad
   path = ${SHARE_BACKUP}
   browseable = yes
   read only = no
   guest ok = yes
   force user = ${SAMBA_USER}
   force group = ${SAMBA_GROUP}
   create mask = 0664
   directory mask = 2775
   inherit permissions = yes
   inherit acls = yes
   vfs objects = full_audit streams_xattr
   full_audit:prefix = %u|%I|%m|%S
   full_audit:success = connect disconnect unlink rmdir rename mkdir
   full_audit:failure = none
   full_audit:facility = LOCAL7
   full_audit:priority = NOTICE
EOF
}

# --- Validar sintaxis del smb.conf candidato ---
validate_samba_config() {
    local candidate="$1"

    run_check "testparm -s '${candidate}' > /dev/null 2>&1" \
        "Validando sintaxis de smb.conf"
}

# --- Instalar configuración si ha cambiado ---
deploy_samba_config() {
    local candidate="$1"

    if [[ -f "${TARGET_CONF}" ]] && cmp -s "${TARGET_CONF}" "${candidate}"; then
        log_info "Samba ya configurado. Sin cambios."
        return 0
    fi

    # Validar antes de desplegar
    if ! validate_samba_config "${candidate}"; then
        log_error "Sintaxis de configuración inválida. Abortando."
        exit 1
    fi

    if [[ -f "${TARGET_CONF}" ]]; then
        create_backup "${TARGET_CONF}"
    fi

    execute_cmd "cp '${candidate}' '${TARGET_CONF}'" "Instalando smb.conf"
    execute_cmd "chmod 644 '${TARGET_CONF}'" "Permisos 644"
    execute_cmd "chown root:root '${TARGET_CONF}'" "Propietario root:root"

    # RISK: Reiniciar smbd corta todas las conexiones activas de clientes.
    # Mitigación: el script solo se ejecuta durante install.sh (mantenimiento
    # planificado) o manualmente. No se ejecuta desde cron.
    execute_cmd "systemctl restart smbd" "Reiniciando smbd"

    # nmbd puede no estar instalado en configuraciones mínimas
    if systemctl list-unit-files 2>/dev/null | grep -q "^nmbd.service"; then
        execute_cmd "systemctl restart nmbd" "Reiniciando nmbd"
    fi

    log_success "Configuración de Samba desplegada."
}

# --- Verificar que Samba está operativo ---
post_checks() {
    if ! check_service_active "smbd"; then
        log_error "smbd no está activo tras la configuración."
        log_error "Diagnóstico: journalctl -u smbd -n 20"
        exit 1
    fi

    local ip
    ip="$(get_ip_address)"

    log_success "NAS Samba operativo."
    log_info "  Shares:"
    log_info "    \\\\${ip}\\${SHARE_NAME_LIBRARY}  → ${SHARE_LIBRARY}"
    log_info "    \\\\${ip}\\${SHARE_NAME_DOWNLOADS}   → ${SHARE_DOWNLOADS}"
    log_info "    \\\\${ip}\\${SHARE_NAME_BACKUP}      → ${SHARE_BACKUP}"
    log_info "  Modo:       público (guest ok = yes, sin contraseña)"
    log_info "  Propietario: ${SAMBA_USER}:${SAMBA_GROUP}"
    log_info "  Papelera:   .recycle/<usuario> en cada share"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    local temp_dir=""

    trap 'rm -rf "${temp_dir:-}"' EXIT
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Configuración de Servidor NAS (Samba)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands systemctl id mktemp cp cmp
    validate_env_vars

    # Validar que el usuario de Samba existe
    if ! id "${SAMBA_USER}" &>/dev/null; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "[DRY-RUN] Usuario '${SAMBA_USER}' no existe (normal en simulación)."
        else
            log_error "Usuario '${SAMBA_USER}' no existe. ¿Se ejecutó 10-users.sh?"
            exit 1
        fi
    fi

    # Avisar si las rutas de los shares no existen
    local share_dir
    for share_dir in "${SHARE_LIBRARY}" "${SHARE_DOWNLOADS}" "${SHARE_BACKUP}"; do
        if [[ ! -d "${share_dir}" ]]; then
            log_warning "Ruta de share inexistente: ${share_dir} (se creará al montar el disco)"
        fi
    done

    # --- 2. Instalación ---
    ensure_package "samba"
    ensure_package "samba-common-bin"

    # --- 3. Generar configuración candidata ---
    temp_dir="$(mktemp -d)"
    local candidate="${temp_dir}/smb.conf"
    render_samba_config "${candidate}"

    # --- 4. Desplegar si ha cambiado ---
    deploy_samba_config "${candidate}"

    # --- 5. Verificación ---
    post_checks
}

main "$@"
