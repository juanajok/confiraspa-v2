#!/bin/bash
# scripts/10-network/firewall.sh
# Descripción: Configuración de Firewall (UFW) con estrategia LAN-Only Hardened
# Autor: Juan José Hipólito (Refactorizado v4 - SSH LAN Only)

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
# Puertos
SSH_PORT="${SSH_PORT:-22}" # Anti Auto-Lockout
WEBMIN_PORT="10000"
PLEX_PORT="32400"
TRANSMISSION_WEB="9091"
TRANSMISSION_PEER="${TRANSMISSION_PEER_PORT:-51413}"
CALIBRE_PORT="8080"
BAZARR_PORT="6767"

# Subredes Privadas (RFC 1918)
# Permitimos acceso desde cualquier red doméstica típica
#readonly PRIVATE_SUBNETS=("192.168.0.0/16" "172.16.0.0/12" "10.0.0.0/8")

# --- DETECCIÓN DINÁMICA DE SUBRED (Smart Security) ---
# Obtenemos la subred actual (ej: 192.168.1.0/24)
# ip -o -f inet addr show: Muestra IPs IPv4 en una línea
# awk: Filtra la interfaz global (eth0/wlan0) y saca el CIDR
CURRENT_SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1)

if [[ -z "$CURRENT_SUBNET" ]]; then
    log_warning "No se pudo detectar la subred. Usando valores por defecto RFC1918."
    readonly PRIVATE_SUBNETS=("192.168.0.0/16" "172.16.0.0/12" "10.0.0.0/8")
else
    log_info "Subred detectada: $CURRENT_SUBNET"
    # Solo permitimos la red real de casa + VPNs típicas (10.x.x.x suele ser Wireguard/Tailscale)
    readonly PRIVATE_SUBNETS=("$CURRENT_SUBNET" "10.0.0.0/8" "100.64.0.0/10")
fi

log_section "Hardening de Red (Firewall UFW)"

# 1. Validaciones
validate_root
ensure_package "ufw"

# --- FUNCIÓN HELPER (DRY) ---
# Abre un puerto solo para las redes privadas (LAN)
allow_lan() {
    local port="$1"
    local proto="$2" # tcp, udp, o vacio para ambos
    local comment="$3"
    
    log_info "  -> Abriendo $port/$proto solo para LAN ($comment)..."
    
    for subnet in "${PRIVATE_SUBNETS[@]}"; do
        if [ -z "$proto" ]; then
            ufw allow from "$subnet" to any port "$port" comment "$comment (LAN)" > /dev/null
        else
            ufw allow from "$subnet" to any port "$port" proto "$proto" comment "$comment (LAN)" > /dev/null
        fi
    done
}

# 2. Reset Inicial (Idempotencia)
log_info "Estado previo: Reseteando reglas..."
ufw --force reset > /dev/null

# 3. Políticas por Defecto
log_info "Política base: Cerrar todo, permitir salida."
ufw default deny incoming
ufw default allow outgoing

# ==========================================
# ZONA 1: ACCESO ADMINISTRATIVO SEGURO
# ==========================================
log_subsection "Zona de Administración (SSH)"

# A. SSH (SOLO LAN) - MEJORA CRÍTICA
# Ya no usamos 'ufw limit' global. Ahora iteramos por las subredes privadas.
# Esto hace que el puerto sea invisible desde internet.
log_info "Configurando SSH en puerto $SSH_PORT (Restringido a LAN)..."

for subnet in "${PRIVATE_SUBNETS[@]}"; do
    ufw allow from "$subnet" to any port "$SSH_PORT" proto tcp comment "SSH Admin (LAN)" > /dev/null
done

# ==========================================
# ZONA 2: ACCESO PÚBLICO (NECESARIO PARA P2P/MEDIA)
# ==========================================
log_subsection "Zona Pública (P2P y Streaming)"

# B. Transmission Peer Port (Necesario para bajar torrents)
log_info "Configurando P2P (Transmission Peers)..."
ufw allow "$TRANSMISSION_PEER"/tcp comment 'Torrent Peer TCP'
ufw allow "$TRANSMISSION_PEER"/udp comment 'Torrent Peer UDP'

# C. Plex (Streaming remoto)
# Necesario si quieres ver tus pelis fuera de casa sin VPN
log_info "Configurando Plex Streaming..."
ufw allow "$PLEX_PORT"/tcp comment 'Plex Main'

# E. aMule (Tráfico P2P)
# Necesario global para tener HighID
ufw allow 4662/tcp comment 'eD2k TCP (Global)'
ufw allow 4672/udp comment 'Kademlia UDP (Global)'

# ==========================================
# ZONA 3: ACCESO PRIVADO (SOLO LAN)
# ==========================================
log_subsection "Zona Privada (Solo LAN/VPN)"

# A. Administración Web
allow_lan "$WEBMIN_PORT" "tcp" "Webmin Admin"

# B. NAS (Samba / Rsync)
log_info "  -> Configurando Samba y Rsync (LAN)..."
for subnet in "${PRIVATE_SUBNETS[@]}"; do
    # Samba App Profile restringido a LAN
    ufw allow from "$subnet" to any app "Samba" comment "Samba Share (LAN)" > /dev/null
    # Rsync Daemon
    ufw allow from "$subnet" to any port 873 proto tcp comment "Rsync Backup (LAN)" > /dev/null
done

# C. Interfaces Web de Gestión (*Arr / Transmission UI / aMule UI)
allow_lan "$TRANSMISSION_WEB" "tcp" "Transmission Web UI"
allow_lan "4711" "tcp" "aMule Web UI"
allow_lan "$BAZARR_PORT" "tcp" "Bazarr UI"
allow_lan "$CALIBRE_PORT" "tcp" "Calibre Server"

# Suite *Arr (Bucle optimizado)
ARR_PORTS=("8989" "7878" "8686" "8787" "9696" "6969")
ARR_NAMES=("Sonarr" "Radarr" "Lidarr" "Readarr" "Prowlarr" "Whisparr")

for i in "${!ARR_PORTS[@]}"; do
    allow_lan "${ARR_PORTS[$i]}" "tcp" "${ARR_NAMES[$i]}"
done

# D. Escritorio Remoto (VNC/XRDP)
allow_lan "3389" "tcp" "XRDP"
allow_lan "5900" "tcp" "VNC"

# ==========================================
# ACTIVACIÓN
# ==========================================
log_subsection "Activación"

log_info "Configurando logging explícito (Low)..."
ufw logging low

# WARNING CRÍTICO PARA EL OPERADOR
log_warning "IMPORTANTE: Si estás conectado por SSH desde fuera de tu red local, esta acción cortará la conexión."
log_info "Activando firewall..."

ufw --force enable
ufw reload

# Verificación
echo ""
log_success "Firewall 'LAN-Hardened' activo."
echo "---------------------------------------------------------"
# Filtramos para mostrar resumen
ufw status numbered | head -n 20
echo "... (ver lista completa con 'sudo ufw status')"
echo "---------------------------------------------------------"