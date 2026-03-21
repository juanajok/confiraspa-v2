#!/usr/bin/env bash
# scripts/30-services/samba.sh
# Configuración idempotente de Samba en modo NAS público para Confiraspa.
#
# Modo de acceso: PÚBLICO (sin contraseña).
# Cualquier dispositivo de la red local puede acceder a los recursos compartidos
# sin autenticación. Los ficheros se crean con el propietario y grupo correctos
# para que Plex, Sonarr, Radarr y Transmission funcionen sin conflictos.
#
# Seguridad: guest account = nobody (sin privilegios de sistema).
# force user / force group en cada share aseguran que los ficheros se crean
# con el propietario correcto sin dar privilegios elevados al invitado.

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

# Cargar .env si no estamos bajo install.sh (ej: --only samba)
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly TARGET_CONF="/etc/samba/smb.conf"

# Variables del .env con defaults seguros
readonly SAMBA_USER="${SMB_USER:-${SYS_USER:-pi}}"
readonly SAMBA_GROUP="${ARR_GROUP:-media}"
readonly SAMBA_WORKGROUP="${SMB_WORKGROUP:-WORKGROUP}"

# Rutas de los shares (del .env)
readonly SHARE_LIBRARY="${PATH_LIBRARY:-/media/WDElements}"
readonly SHARE_BACKUP="${PATH_BACKUP:-/media/Backup}"
readonly SHARE_DOWNLOADS="${DIR_TORRENTS:-/media/DiscoDuro/completos}"

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
        log_warning "Configuración de Samba restaurada desde backup."
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

# --- Validar comandos del paquete (se omiten en dry-run) ---
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

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Generar smb.conf candidato en directorio temporal ---
# Genera la configuración directamente por heredoc (sin plantilla externa).
# Esto hace el script autocontenido y más fácil de auditar.
render_samba_config() {
    local output_file="$1"

    cat > "${output_file}" <<EOF
# Generado por Confiraspa — no editar manualmente.
# Modo: NAS Público (acceso sin contraseña desde la red local).
# Regenerar con: sudo ./install.sh --only samba

[global]
   workgroup = ${SAMBA_WORKGROUP}
   server string = Confiraspa NAS @ %h
   netbios name = %h

   # Acceso público: invitados mapeados a 'nobody' (sin privilegios).
   # force user/group en cada share controla la identidad real de escritura.
   security = user
   map to guest = Bad User
   guest account = nobody
   dns proxy = no

   # Logging
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

   # Rendimiento optimizado para Raspberry Pi
   server min protocol = SMB2
   socket options = TCP_NODELAY IPTOS_LOWDELAY
   use sendfile = yes
   aio read size = 16384
   aio write size = 16384

[WDElements]
   comment = Biblioteca Multimedia Principal
   path = ${SHARE_LIBRARY}
   browseable = yes
   read only = no
   guest ok = yes
   force user = ${SAMBA_USER}
   force group = ${SAMBA_GROUP}
   create mask = 0664
   directory mask = 2775

[Descargas]
   comment = Carpeta de Descargas Completas
   path = ${SHARE_DOWNLOADS}
   browseable = yes
   read only = no
   guest ok = yes
   force user = ${SAMBA_USER}
   force group = ${SAMBA_GROUP}
   create mask = 0664
   directory mask = 2775

[Backup]
   comment = Copias de Seguridad del Sistema
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

# --- Instalar configuración solo si ha cambiado (idempotente) ---
install_config_if_changed() {
    local candidate="$1"

    if [[ -f "${TARGET_CONF}" ]] && cmp -s "${TARGET_CONF}" "${candidate}"; then
        log_info "Configuración de Samba sin cambios."
        return 1  # Sin cambios
    fi

    # Backup de la configuración existente para rollback en on_error
    if [[ -f "${TARGET_CONF}" ]]; then
        backup_file="${TARGET_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
        execute_cmd "cp -a '${TARGET_CONF}' '${backup_file}'" \
            "Backup de smb.conf existente"
    fi

    # Validar sintaxis antes de instalar
    if ! run_check "testparm -s '${candidate}'" "Validando sintaxis de smb.conf"; then
        log_error "Configuración candidata de Samba inválida. No se instala."
        return 1
    fi

    execute_cmd "cp '${candidate}' '${TARGET_CONF}'" \
        "Instalando nueva configuración smb.conf"

    return 0  # Hubo cambios
}

# --- Asegurar que el directorio de descargas existe ---
ensure_downloads_dir() {
    if [[ -d "${SHARE_DOWNLOADS}" ]]; then
        return 0
    fi

    execute_cmd "install -d -o '${SAMBA_USER}' -g '${SAMBA_GROUP}' -m 2775 '${SHARE_DOWNLOADS}'" \
        "Creando directorio de descargas: ${SHARE_DOWNLOADS}"
}

# --- Arrancar y verificar servicio ---
start_and_verify() {
    execute_cmd "systemctl daemon-reload" "Recargando systemd"

    # smbd es el servicio principal. nmbd gestiona NetBIOS (descubrimiento en red).
    # nmbd puede no existir en Samba 4 moderno — tratarlo como opcional.
    execute_cmd "systemctl enable smbd" "Habilitando smbd"
    execute_cmd "systemctl restart smbd" "Reiniciando smbd"

    if systemctl list-unit-files 2>/dev/null | grep -q "^nmbd.service"; then
        execute_cmd "systemctl enable nmbd" "Habilitando nmbd"
        execute_cmd "systemctl restart nmbd" "Reiniciando nmbd"
    fi
}

# --- Comprobaciones post-instalación ---
post_checks() {
    if ! check_service_active "smbd"; then
        log_error "Samba (smbd) no está activo."
        log_error "Diagnóstico: journalctl -u smbd -n 50"
        exit 1
    fi

    local ip
    ip="$(get_ip_address)"

    log_success "NAS Público operativo (acceso sin contraseña)."
    log_info "  \\\\${ip}\\WDElements  — Biblioteca multimedia"
    log_info "  \\\\${ip}\\Descargas   — Descargas completas"
    log_info "  \\\\${ip}\\Backup      — Copias de seguridad"
    log_info ""
    log_info "  Desde Linux:  smb://${ip}/WDElements"
    log_info "  Nota: Conectar como 'Anónimo' o 'Invitado'."
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    # --- Variables de estado ---
    local backup_file=""
    local temp_dir=""

    trap 'rm -rf "${temp_dir:-}"' EXIT
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Configuración de Servidor NAS (Samba)"

    # --- 1. Validaciones previas ---
    validate_root
    require_system_commands systemctl id getent grep awk

    # --- 2. Instalación de paquetes ---
    ensure_package "samba"
    ensure_package "samba-common-bin"

    require_service_commands testparm

    # --- 3. Validar usuario del sistema ---
    # El usuario forzado en los shares debe existir para que force user funcione.
    if ! id "${SAMBA_USER}" &>/dev/null; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "[DRY-RUN] Usuario '${SAMBA_USER}' no existe (normal en simulación)."
        else
            log_error "Usuario '${SAMBA_USER}' no existe. Ejecuta 10-users.sh primero."
            exit 1
        fi
    fi

    # Asegurar que el usuario pertenece al grupo multimedia
    if id "${SAMBA_USER}" &>/dev/null && ! id -nG "${SAMBA_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx "${SAMBA_GROUP}"; then
        execute_cmd "usermod -aG '${SAMBA_GROUP}' '${SAMBA_USER}'" \
            "Añadiendo '${SAMBA_USER}' al grupo '${SAMBA_GROUP}'"
    fi

    # --- 4. Directorio de descargas ---
    ensure_downloads_dir

    # --- 5. Generar e instalar configuración ---
    temp_dir="$(mktemp -d)"
    local candidate="${temp_dir}/smb.conf.candidate"

    render_samba_config "${candidate}"

    local config_changed=false
    if install_config_if_changed "${candidate}"; then
        config_changed=true
    fi

    # --- 6. Arranque ---
    if [[ "${config_changed}" == "true" ]]; then
        log_info "Configuración actualizada — reiniciando Samba..."
        start_and_verify
    else
        execute_cmd "systemctl enable smbd" "Asegurando smbd habilitado"
        if ! check_service_active "smbd"; then
            start_and_verify
        else
            log_info "Samba ya activo y sin cambios de configuración."
        fi
    fi

    # --- 7. Verificación ---
    post_checks
}

main "$@"