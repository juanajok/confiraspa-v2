#!/usr/bin/env bash
#
# scripts/30-services/samba.sh
# Descripción: Configuración robusta e idempotente de Samba (NAS Mode).
# Autor: Juan José Hipólito (Refactorizado v5.0 - Final Enterprise Edition)

set -euo pipefail
IFS=$'\n\t'

# --- CABECERA UNIVERSAL ---
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly SAMBA_CONFIG_FILE="/etc/samba/smb.conf"

# Variables de estado
DRY_RUN="${DRY_RUN:-false}"
SAMBA_CONFIG_BACKUP=""
TEMP_DIR_PATH=""

# Carga de librerías
source "${REPO_ROOT}/lib/colors.sh"
source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

# =============================================================================
# MANEJO DE ERRORES Y LIMPIEZA
# =============================================================================

on_error() {
    local exit_code="${1:-1}"
    log_error "Fallo crítico en $SCRIPT_NAME (Exit code $exit_code)."
    
    if [[ -n "${SAMBA_CONFIG_BACKUP}" && "${DRY_RUN}" != "true" ]]; then
        log_warning "Iniciando rollback de configuración de Samba..."
        cp -f "${SAMBA_CONFIG_BACKUP}" "${SAMBA_CONFIG_FILE}" || true
    fi
    exit "${exit_code}"
}

cleanup() {
    if [[ -n "${TEMP_DIR_PATH:-}" && -d "${TEMP_DIR_PATH}" ]]; then
        rm -rf "${TEMP_DIR_PATH}"
    fi
}

trap 'on_error "$?"' ERR
trap cleanup EXIT

# =============================================================================
# FUNCIONES DE APOYO
# =============================================================================

ensure_user_in_group() {
    local user_name="$1"
    local group_name="$2"

    assert_system_state "getent group '${group_name}'" "El grupo '${group_name}' no existe."

    # En Dry-run, si el usuario no existe todavía, no podemos validar sus grupos
    if ! id -u "${user_name}" >/dev/null 2>&1; then
        [[ "${DRY_RUN}" == "true" ]] && return 0
        exit 1
    fi

    if id -nG "${user_name}" | grep -qw "${group_name}"; then
        log_info "El usuario '${user_name}' ya pertenece al grupo '${group_name}'."
    else
        execute_cmd "Añadiendo usuario al grupo" "usermod -aG '${group_name}' '${user_name}'"
    fi
}

render_samba_config() {
    local output_file="$1"
    local samba_user="${SMB_USER:-${SYS_USER}}"
    local force_group="${ARR_GROUP:-media}"

    log_info "Renderizando nueva configuración de Samba..."
    cat > "${output_file}" <<EOF
[global]
   workgroup = ${SMB_WORKGROUP:-WORKGROUP}
   server string = Confiraspa NAS @ ${HOSTNAME}
   netbios name = ${HOSTNAME}
   security = user
   map to guest = Bad User
   dns proxy = no

   # Optimización de Logs
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

   # Rendimiento para Raspberry Pi
   server min protocol = SMB2
   socket options = TCP_NODELAY IPTOS_LOWDELAY
   use sendfile = yes
   aio read size = 16384
   aio write size = 16384

[Descargas]
   comment = Carpeta de Descargas Completas
   path = ${DIR_TORRENTS}
   browseable = yes
   read only = no
   valid users = ${samba_user} @${force_group}
   force group = ${force_group}
   create mask = 0664
   directory mask = 2775

[WDElements]
   comment = Biblioteca Multimedia Principal
   path = ${PATH_LIBRARY}
   browseable = yes
   read only = no
   valid users = ${samba_user} @${force_group}
   force group = ${force_group}
   create mask = 0664
   directory mask = 2775

[Backup]
   comment = Copias de Seguridad del Sistema
   path = ${PATH_BACKUP}
   browseable = yes
   read only = no
   valid users = ${samba_user} @${force_group}
   force group = ${force_group}
   create mask = 0664
   directory mask = 2775
EOF
}

# =============================================================================
# MAIN LOGIC
# =============================================================================

main() {
    validate_root
    
    # 1. Validar herramientas básicas
    require_system_commands install systemctl id getent awk grep mktemp
    
    # 2. Definir usuario objetivo
    local samba_user="${SMB_USER:-${SYS_USER}}"
    log_section "Configuración de Servidor NAS (Samba)"
    log_info "Objetivo: Compartir recursos para el usuario '$samba_user'"

    # 3. Instalación de paquetes
    ensure_package "samba"
    ensure_package "samba-common-bin"

    # 4. Validar comandos del servicio (indulgente en Dry-Run)
    require_service_commands pdbedit smbpasswd testparm

    # 5. Aserción de estado del sistema
    assert_system_state "id -u '${samba_user}'" "El usuario Linux '$samba_user' no existe. Ejecute 10-users.sh primero."
    ensure_user_in_group "${samba_user}" "${ARR_GROUP:-media}"

    # 6. Preparación de configuración
    TEMP_DIR_PATH="$(mktemp -d)"
    local candidate_config="${TEMP_DIR_PATH}/smb.conf"
    
    render_samba_config "${candidate_config}"

    # 7. Validación atómica
    log_info "Validando sintaxis de la configuración..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "[DRY-RUN] Validación de testparm omitida (binario podría no existir)."
    else
        testparm -s "${candidate_config}" >/dev/null 2>&1 || {
            log_error "La configuración de Samba generada es inválida."
            exit 1
        }
    fi

    # 8. Despliegue de archivo (con Backup)
    if ! cmp -s "${candidate_config}" "${SAMBA_CONFIG_FILE}" 2>/dev/null; then
        if [[ -f "${SAMBA_CONFIG_FILE}" && "${DRY_RUN}" != "true" ]]; then
            SAMBA_CONFIG_BACKUP="${SAMBA_CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
            cp -a "${SAMBA_CONFIG_FILE}" "${SAMBA_CONFIG_BACKUP}"
            log_info "Backup creado en $SAMBA_CONFIG_BACKUP"
        fi

        execute_cmd "Instalando nueva configuración smb.conf" \
            "install -o root -g root -m 0644 ${candidate_config} ${SAMBA_CONFIG_FILE}"
    else
        log_info "La configuración de Samba no ha cambiado. Saltando escritura."
    fi

    # 9. Sincronización de contraseña Samba
    log_info "Sincronizando credenciales de Samba..."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warning "[DRY-RUN] Se omitiría la actualización de smbpasswd."
    else
        if pdbedit -L 2>/dev/null | grep -q "^${samba_user}:"; then
            log_info "Actualizando contraseña para usuario Samba existente."
        else
            log_info "Creando nueva entrada en la base de datos de Samba."
        fi
        # Inyección segura de contraseña
        (echo "${SMB_PASS}"; echo "${SMB_PASS}") | smbpasswd -s -a "${samba_user}" >/dev/null
        smbpasswd -e "${samba_user}" >/dev/null
    fi

    # 10. Gestión del servicio
    execute_cmd "Recargando demonios de sistema" "systemctl daemon-reload"
    execute_cmd "Habilitando servicio Samba" "systemctl enable smbd"
    execute_cmd "Reiniciando servicio Samba" "systemctl restart smbd"

    # 11. Verificación final (Health Check)
    if check_service_active "smbd"; then
        local host_ip
        host_ip=$(get_ip_address)
        log_success "Samba está operativo en $host_ip"
    else
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_success "[DRY-RUN] Simulación de servicio finalizada."
        else
            log_error "Samba no pudo arrancar. Revisa 'journalctl -u smbd'"
            exit 1
        fi
    fi
}

main "$@"