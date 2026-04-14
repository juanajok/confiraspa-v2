#!/usr/bin/env bash
# scripts/30-services/samba.sh
# Configuración idempotente de Samba como NAS doméstico para Confiraspa.
#
# Modo de acceso: público (guest ok = yes, restrict anonymous = 0).
# Compatible con Windows, macOS, Android, Smart TVs y tablets.
# Todos los ficheros se crean como SAMBA_USER:MEDIA_GROUP con permisos
# 664/2775 (SetGID para herencia de grupo).
#
# VFS por share:
#   - recycle: papelera de reciclaje por usuario (.recycle/<usuario>)
#   - Nota: streams_xattr y full_audit se excluyen deliberadamente.
#     streams_xattr causa errores fatales en NTFS, y full_audit puede
#     bloquear Samba si AppArmor restringe el acceso a syslog.
#
# AppArmor: se pone smbd en modo complain para evitar bloqueos de acceso
# a /media en discos montados con nofail.
#
# Compatibilidad:
#   - Debian 12/13 (Bookworm/Trixie)
#   - Raspberry Pi 4/5
#   - Discos NTFS (vía ntfs3) y EXT4

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

readonly SHARE_LIBRARY="${PATH_LIBRARY:-/media/WDElements}"
readonly SHARE_DOWNLOADS="${DIR_TORRENTS:-/media/DiscoDuro/torrents/completos}"
readonly SHARE_BACKUP="${PATH_BACKUP:-/media/Backup}"

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

validate_env_vars() {
    validate_var "SYS_USER" "${SYS_USER:-}"
    validate_var "ARR_GROUP" "${ARR_GROUP:-}"
    validate_var "PATH_LIBRARY" "${PATH_LIBRARY:-}"
    validate_var "PATH_BACKUP" "${PATH_BACKUP:-}"
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Generar smb.conf en un fichero candidato ---
render_samba_config() {
    local output_file="$1"

    cat > "${output_file}" <<EOF
# Generado por Confiraspa — NAS doméstico con papelera de reciclaje

[global]
   workgroup = ${SAMBA_WORKGROUP}
   server string = Confiraspa NAS
   netbios name = %h

   security = user
   map to guest = Bad User
   guest account = nobody

   # restrict anonymous = 0: permite listado anónimo de shares.
   # Necesario para Android, Smart TVs y tablets que listan recursos
   # de forma anónima antes de intentar entrar como invitados.
   # SECURITY: Seguro solo en redes LAN privadas. No usar en redes
   # abiertas o VLANs de invitados — expone nombres de shares.
   restrict anonymous = 0

   # SECURITY: SMB1 desactivado (vulnerabilidades EternalBlue/WannaCry)
   server min protocol = SMB2

   # unix extensions = no: evita lookups innecesarios con clientes
   # Windows/Android/Smart TV que no entienden extensiones POSIX.
   unix extensions = no

   # Rendimiento para RPi con discos USB
   use sendfile = yes
   aio read size = 1
   aio write size = 1
   getwd cache = yes

   # Caché de nombres de directorio: reduce llamadas stat() en bibliotecas
   # grandes (12.000+ libros, miles de subdirectorios de series).
   # Coste: ~200KB RAM (~100 bytes/entrada). Irrelevante en RPi 4/8GB.
   directory name cache size = 2000

   # Logging
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

   # Cierra conexiones inactivas tras 15 minutos. Libera RAM en RPi
   # de clientes que se desconectan sin cerrar sesión (Smart TVs, tablets).
   deadtime = 15

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

# --- Desbloquear AppArmor para smbd ---
# RISK: aa-complain reduce la seguridad de AppArmor para smbd.
# Mitigación: solo pone smbd en modo complain (no lo deshabilita).
# Necesario porque en Debian 13 / RPi OS Bookworm, AppArmor bloquea
# el acceso de smbd a puntos de montaje en /media con discos USB.
configure_apparmor() {
    if ! command -v aa-complain &>/dev/null; then
        log_info "AppArmor no disponible. Saltando configuración."
        return 0
    fi

    # Comprobar si smbd ya está en modo complain
    if aa-status 2>/dev/null | grep -A999 "complain mode" | grep -q "smbd"; then
        log_info "AppArmor: smbd ya en modo complain."
        return 0
    fi

    execute_cmd "aa-complain /usr/sbin/smbd" \
        "AppArmor: poniendo smbd en modo complain (acceso a /media)"
}

# --- Asegurar permisos de los puntos de montaje ---
configure_mount_permissions() {
    # /media necesita traversal (755) para que smbd pueda acceder a los shares
    execute_cmd "chmod 755 /media" "Traversal en /media"

    local dir
    for dir in "${SHARE_LIBRARY}" "${SHARE_DOWNLOADS}" "${SHARE_BACKUP}"; do
        if [[ -z "${dir}" ]]; then
            continue
        fi

        if [[ -d "${dir}" ]]; then
            # En NTFS (ntfs3), chown no tiene efecto real — los permisos se
            # gestionan vía mount options (uid/gid). Lo ejecutamos igualmente
            # para EXT4 y logamos el aviso para transparencia.
            if mount | grep -q "${dir}.*ntfs"; then
                log_info "NTFS detectado en $(basename "${dir}") — permisos gestionados por mount options"
            fi
            execute_cmd "chown '${SAMBA_USER}:${SAMBA_GROUP}' '${dir}'" \
                "Propietario: $(basename "${dir}")"
            execute_cmd "chmod 775 '${dir}'" \
                "Permisos 775: $(basename "${dir}")"
        else
            log_warning "Ruta de share no encontrada: ${dir} (se creará al montar el disco)"
        fi
    done
}

# --- Validar y desplegar smb.conf ---
deploy_samba_config() {
    local candidate="$1"

    if [[ -f "${TARGET_CONF}" ]] && cmp -s "${TARGET_CONF}" "${candidate}"; then
        log_info "Configuración de Samba sin cambios."
        return 0
    fi

    # Validar sintaxis antes de desplegar
    if ! run_check "testparm -s '${candidate}' > /dev/null 2>&1" \
         "Validando sintaxis de smb.conf"; then
        log_error "smb.conf inválido. Abortando despliegue."
        exit 1
    fi

    if [[ -f "${TARGET_CONF}" ]]; then
        create_backup "${TARGET_CONF}"
    fi

    execute_cmd "cp '${candidate}' '${TARGET_CONF}'" "Instalando smb.conf"
    execute_cmd "chmod 644 '${TARGET_CONF}'" "Permisos 644"
    execute_cmd "chown root:root '${TARGET_CONF}'" "Propietario root:root"

    # RISK: Reiniciar smbd corta todas las conexiones activas de clientes.
    # Mitigación: solo se ejecuta durante install.sh o manualmente, no desde cron.
    execute_cmd "systemctl restart smbd" "Reiniciando smbd"

    # nmbd puede no existir en configuraciones mínimas
    if systemctl is-enabled nmbd &>/dev/null; then
        execute_cmd "systemctl restart nmbd" "Reiniciando nmbd"
    fi

    log_success "Configuración de Samba desplegada."
}

# --- Verificación final ---
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
    log_info "  Papelera:   .recycle/<usuario> en Library y Descargas"
    log_info "  Tip Windows: si no ves los shares, ejecuta: net use * /delete /y"
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
    require_system_commands systemctl mktemp cp cmp chmod chown
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

    # --- 2. Paquetes ---
    ensure_package "samba"
    ensure_package "samba-vfs-modules"
    ensure_package "apparmor-utils"

    # --- 3. AppArmor ---
    configure_apparmor

    # --- 4. Permisos de puntos de montaje ---
    configure_mount_permissions

    # --- 5. Generar y desplegar configuración ---
    temp_dir="$(mktemp -d)"
    local candidate="${temp_dir}/smb.conf"
    render_samba_config "${candidate}"
    deploy_samba_config "${candidate}"

    # --- 6. Verificación ---
    post_checks
}

main "$@"