#!/usr/bin/env bash
# scripts/10-network/firewall.sh
# Configuración idempotente de UFW con estrategia LAN-Only Hardened.
#
# Todos los puertos se leen del .env con defaults estándar. Si cambias un
# puerto en un servicio (ej: CALIBRE_PORT=9090), al re-ejecutar este script
# el firewall se actualiza automáticamente.
#
# Estructura de zonas:
#   - Zona Admin:   SSH (solo LAN)
#   - Zona Pública: P2P/Streaming (accesible desde Internet para funcionar)
#   - Zona Privada: Web UIs de todos los servicios (solo LAN)

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

# Cargar .env si no estamos bajo install.sh (ej: --only firewall)
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# ===========================================================================
# PUERTOS — todos del .env con defaults estándar
# ===========================================================================

# Administración
readonly FW_SSH_PORT="${SSH_PORT:-22}"

# P2P / Streaming (necesitan acceso público para funcionar)
readonly FW_PLEX_PORT="${PLEX_PORT:-32400}"
readonly FW_TRANSMISSION_PEER="${TRANSMISSION_PEER_PORT:-51413}"
readonly FW_AMULE_TCP="4662"     # eD2k — protocolo fijo, no configurable
readonly FW_AMULE_UDP="4672"     # Kademlia — protocolo fijo, no configurable

# Web UIs (solo LAN)
readonly FW_WEBMIN_PORT="${WEBMIN_PORT:-10000}"
readonly FW_TRANSMISSION_WEB="${TRANSMISSION_WEB_PORT:-9091}"
readonly FW_AMULE_WEB="4711"
readonly FW_CALIBRE_PORT="${CALIBRE_PORT:-8083}"
readonly FW_BAZARR_PORT="${BAZARR_PORT:-6767}"
readonly FW_XRDP_PORT="3389"
readonly FW_VNC_REALVNC="5900"
readonly FW_VNC_TIGERVNC="5901"

# Suite *Arr — puertos estándar (no suelen cambiarse)
readonly FW_SONARR_PORT="${SONARR_PORT:-8989}"
readonly FW_RADARR_PORT="${RADARR_PORT:-7878}"
readonly FW_LIDARR_PORT="${LIDARR_PORT:-8686}"
readonly FW_READARR_PORT="${READARR_PORT:-8787}"
readonly FW_PROWLARR_PORT="${PROWLARR_PORT:-9696}"
readonly FW_WHISPARR_PORT="${WHISPARR_PORT:-6969}"

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

# --- Detectar subred local ---
detect_subnets() {
    local current_subnet
    current_subnet=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1)

    if [[ -z "${current_subnet}" ]]; then
        log_warning "No se pudo detectar la subred. Usando RFC1918 completo."
        PRIVATE_SUBNETS=("192.168.0.0/16" "172.16.0.0/12" "10.0.0.0/8")
    else
        log_info "Subred detectada: ${current_subnet}"
        # Subred real + rangos para VPN (Tailscale usa 100.64.0.0/10)
        PRIVATE_SUBNETS=("${current_subnet}" "10.0.0.0/8" "100.64.0.0/10")
    fi
}

# --- Permitir un puerto solo desde LAN ---
# Uso: allow_lan "puerto" "proto" "Descripción del servicio"
allow_lan() {
    local port="$1"
    local proto="$2"
    local comment="$3"

    log_info "  -> ${port}/${proto} para LAN (${comment})..."

    local subnet
    for subnet in "${PRIVATE_SUBNETS[@]}"; do
        execute_cmd "ufw allow from ${subnet} to any port ${port} proto ${proto} comment '${comment} (LAN)'"
    done
}

# --- Permitir un puerto desde cualquier origen ---
# Uso: allow_public "puerto" "proto" "Descripción"
allow_public() {
    local port="$1"
    local proto="$2"
    local comment="$3"

    log_info "  -> ${port}/${proto} público (${comment})..."
    execute_cmd "ufw allow ${port}/${proto} comment '${comment}'"
}

# --- Reset y políticas base ---
configure_base_policy() {
    log_info "Reseteando reglas anteriores..."
    execute_cmd "ufw --force reset" "Reset UFW"

    log_info "Política base: denegar entrada, permitir salida."
    execute_cmd "ufw default deny incoming" "Deny incoming"
    execute_cmd "ufw default allow outgoing" "Allow outgoing"
}

# --- Zona 1: Administración (SSH solo LAN) ---
configure_admin_zone() {
    log_subsection "Zona Admin (SSH)"
    allow_lan "${FW_SSH_PORT}" "tcp" "SSH Admin"
}

# --- Zona 2: Servicios públicos (P2P y streaming) ---
# Estos puertos necesitan acceso desde Internet para funcionar.
# Sin ellos, Transmission no puede recibir peers y Plex no puede
# hacer streaming remoto.
configure_public_zone() {
    log_subsection "Zona Pública (P2P y Streaming)"

    log_info "Configurando Transmission P2P..."
    allow_public "${FW_TRANSMISSION_PEER}" "tcp" "Torrent Peer TCP"
    allow_public "${FW_TRANSMISSION_PEER}" "udp" "Torrent Peer UDP"

    log_info "Configurando Plex Streaming..."
    allow_public "${FW_PLEX_PORT}" "tcp" "Plex Main"

    log_info "Configurando aMule P2P..."
    allow_public "${FW_AMULE_TCP}" "tcp" "eD2k TCP"
    allow_public "${FW_AMULE_UDP}" "udp" "Kademlia UDP"
}

# --- Zona 3: Servicios privados (Web UIs solo LAN) ---
configure_private_zone() {
    log_subsection "Zona Privada (Solo LAN)"

    # Samba y Rsync — puertos múltiples, manejo especial
    log_info "Configurando Samba y Rsync..."
    local subnet
    for subnet in "${PRIVATE_SUBNETS[@]}"; do
        execute_cmd "ufw allow from ${subnet} to any port 137,138 proto udp comment 'Samba UDP (LAN)'"
        execute_cmd "ufw allow from ${subnet} to any port 139,445 proto tcp comment 'Samba TCP (LAN)'"
        execute_cmd "ufw allow from ${subnet} to any port 873 proto tcp comment 'Rsync Backup (LAN)'"
    done

    # Administración web
    allow_lan "${FW_WEBMIN_PORT}" "tcp" "Webmin Admin"

    # Clientes de descarga
    allow_lan "${FW_TRANSMISSION_WEB}" "tcp" "Transmission Web UI"
    allow_lan "${FW_AMULE_WEB}" "tcp" "aMule Web UI"

    # Multimedia
    allow_lan "${FW_CALIBRE_PORT}" "tcp" "Calibre Content Server"
    allow_lan "${FW_BAZARR_PORT}" "tcp" "Bazarr Subtítulos"

    # Suite *Arr
    allow_lan "${FW_SONARR_PORT}" "tcp" "Sonarr"
    allow_lan "${FW_RADARR_PORT}" "tcp" "Radarr"
    allow_lan "${FW_LIDARR_PORT}" "tcp" "Lidarr"
    allow_lan "${FW_READARR_PORT}" "tcp" "Readarr"
    allow_lan "${FW_PROWLARR_PORT}" "tcp" "Prowlarr"
    allow_lan "${FW_WHISPARR_PORT}" "tcp" "Whisparr"

    # Acceso remoto (escritorio)
    allow_lan "${FW_XRDP_PORT}" "tcp" "XRDP"
    allow_lan "${FW_VNC_REALVNC}" "tcp" "VNC (WayVNC/RealVNC)"
    allow_lan "${FW_VNC_TIGERVNC}" "tcp" "VNC (TigerVNC)"
}

# --- Activar UFW ---
activate_firewall() {
    log_subsection "Activación"

    execute_cmd "ufw logging low" "Logging nivel bajo"

    log_warning "IMPORTANTE: Si estás conectado por SSH desde fuera de la LAN, esta acción cortará la conexión."

    execute_cmd "ufw --force enable" "Activando UFW"
    execute_cmd "ufw reload" "Recargando reglas"
}

# --- Resumen ---
show_summary() {
    log_success "Firewall LAN-Hardened activo."
    log_info "Resumen de zonas:"
    log_info "  Admin:   SSH :${FW_SSH_PORT} (solo LAN)"
    log_info "  Público: Plex :${FW_PLEX_PORT}, Torrent :${FW_TRANSMISSION_PEER}, aMule :${FW_AMULE_TCP}/${FW_AMULE_UDP}"
    log_info "  Privado: Web UIs de todos los servicios (solo LAN)"
    log_info ""
    log_info "Puertos configurables via .env:"
    log_info "  SSH_PORT, PLEX_PORT, TRANSMISSION_PEER_PORT, CALIBRE_PORT,"
    log_info "  WEBMIN_PORT, BAZARR_PORT, SONARR_PORT, RADARR_PORT, etc."
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Hardening de Red (Firewall UFW)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands ip awk
    ensure_package "ufw"

    # --- 2. Detectar subred ---
    # Variable de módulo — usada por allow_lan
    local -a PRIVATE_SUBNETS=()
    detect_subnets

    # --- 3. Reset y políticas base ---
    configure_base_policy

    # --- 4. Zonas ---
    configure_admin_zone
    configure_public_zone
    configure_private_zone

    # --- 5. Activar ---
    activate_firewall

    # --- 6. Resumen ---
    show_summary
}

main "$@"