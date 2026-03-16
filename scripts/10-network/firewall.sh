#!/bin/bash
# scripts/10-network/firewall.sh
# Descripción: Configuración de Firewall (UFW) con estrategia LAN-Only Hardened
# Autor: Juan José Hipólito (Refactorizado v4.1 - Fix Syntax)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# --- VARIABLES Y CONSTANTES ---
SSH_PORT="${SSH_PORT:-22}" 
WEBMIN_PORT="10000"
PLEX_PORT="32400"
TRANSMISSION_WEB="9091"
TRANSMISSION_PEER="${TRANSMISSION_PEER_PORT:-51413}"
CALIBRE_PORT="8080"
BAZARR_PORT="6767"

# --- DETECCIÓN DINÁMICA DE SUBRED ---
CURRENT_SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1)

if [[ -z "$CURRENT_SUBNET" ]]; then
    log_warning "No se pudo detectar la subred. Usando valores por defecto RFC1918."
    readonly PRIVATE_SUBNETS=("192.168.0.0/16" "172.16.0.0/12" "10.0.0.0/8")
else
    log_info "Subred detectada: $CURRENT_SUBNET"
    readonly PRIVATE_SUBNETS=("$CURRENT_SUBNET" "10.0.0.0/8" "100.64.0.0/10")
fi

log_section "Hardening de Red (Firewall UFW)"

# 1. Validaciones
validate_root
ensure_package "ufw"

# --- FUNCIÓN HELPER (DRY) ---
allow_lan() {
    local port="$1"
    local proto="$2"
    local comment="$3"
    
    log_info "  -> Configurando $port/$proto para LAN ($comment)..."
    
    for subnet in "${PRIVATE_SUBNETS[@]}"; do
        if [ -z "$proto" ]; then
            # CORRECCIÓN: Comillas simples para el comentario interno
            execute_cmd "ufw allow from $subnet to any port $port comment '$comment (LAN)'"
        else
            execute_cmd "ufw allow from $subnet to any port $port proto $proto comment '$comment (LAN)'"
        fi
    done
}

# 2. Reset Inicial
log_info "Estado previo: Reseteando reglas..."
execute_cmd "ufw --force reset > /dev/null"

# 3. Políticas por Defecto
log_info "Política base: Cerrar todo, permitir salida."
execute_cmd "ufw default deny incoming"
execute_cmd "ufw default allow outgoing"

# ==========================================
# ZONA 1: ACCESO ADMINISTRATIVO SEGURO
# ==========================================
log_subsection "Zona de Administración (SSH)"

log_info "Configurando SSH en puerto $SSH_PORT (Restringido a LAN)..."
for subnet in "${PRIVATE_SUBNETS[@]}"; do
    # CORRECCIÓN: Sintaxis limpia para execute_cmd
    execute_cmd "ufw allow from $subnet to any port $SSH_PORT proto tcp comment 'SSH Admin (LAN)'"
done

# ==========================================
# ZONA 2: ACCESO PÚBLICO (NECESARIO PARA P2P/MEDIA)
# ==========================================
log_subsection "Zona Pública (P2P y Streaming)"

log_info "Configurando P2P (Transmission Peers)..."
execute_cmd "ufw allow $TRANSMISSION_PEER/tcp comment 'Torrent Peer TCP'"
execute_cmd "ufw allow $TRANSMISSION_PEER/udp comment 'Torrent Peer UDP'"

log_info "Configurando Plex Streaming..."
execute_cmd "ufw allow $PLEX_PORT/tcp comment 'Plex Main'"

log_info "Configurando aMule..."
execute_cmd "ufw allow 4662/tcp comment 'eD2k TCP (Global)'"
execute_cmd "ufw allow 4672/udp comment 'Kademlia UDP (Global)'"

# ==========================================
# ZONA 3: ACCESO PRIVADO (SOLO LAN)
# ==========================================
log_subsection "Zona Privada (Solo LAN/VPN)"

allow_lan "$WEBMIN_PORT" "tcp" "Webmin Admin"

log_info "  -> Configurando Samba y Rsync (LAN)..."
for subnet in "${PRIVATE_SUBNETS[@]}"; do
    execute_cmd "ufw allow from $subnet to any port 137,138 proto udp comment 'Samba UDP (LAN)'"
    execute_cmd "ufw allow from $subnet to any port 139,445 proto tcp comment 'Samba TCP (LAN)'"
    execute_cmd "ufw allow from $subnet to any port 873 proto tcp comment 'Rsync Backup (LAN)'"
done

allow_lan "$TRANSMISSION_WEB" "tcp" "Transmission Web UI"
allow_lan "4711" "tcp" "aMule Web UI"
allow_lan "$BAZARR_PORT" "tcp" "Bazarr UI"
allow_lan "$CALIBRE_PORT" "tcp" "Calibre Server"

ARR_PORTS=("8989" "7878" "8686" "8787" "9696" "6969")
ARR_NAMES=("Sonarr" "Radarr" "Lidarr" "Readarr" "Prowlarr" "Whisparr")

for i in "${!ARR_PORTS[@]}"; do
    allow_lan "${ARR_PORTS[$i]}" "tcp" "${ARR_NAMES[$i]}"
done

allow_lan "3389" "tcp" "XRDP"
allow_lan "5900" "tcp" "VNC"

# ==========================================
# ACTIVACIÓN
# ==========================================
log_subsection "Activación"

execute_cmd "ufw logging low"

log_warning "IMPORTANTE: Si estás conectado por SSH desde fuera de tu red local, esta acción cortará la conexión."
log_info "Activando firewall..."

execute_cmd "ufw --force enable"
execute_cmd "ufw reload"

echo ""
log_success "Firewall 'LAN-Hardened' activo."
echo "---------------------------------------------------------"
execute_cmd "ufw status numbered"
echo "---------------------------------------------------------"