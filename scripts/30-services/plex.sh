#!/bin/bash
# scripts/30-services/plex.sh
# Descripción: Instalación de Plex Media Server (Repo Oficial) con soporte NAS y Transcoding
# Autor: Juan José Hipólito (Refactorizado v3 - Final Release)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# --- CONSTANTES ---
readonly SERVICE="plexmediaserver"
readonly PLEX_USER="plex"
# Grupo multimedia definido en .env (para acceso a discos)
readonly MEDIA_GROUP="${ARR_GROUP:-media}"

# Token Opcional (Definido en .env)
PLEX_CLAIM_TOKEN="${PLEX_CLAIM_TOKEN:-}"

log_section "Instalación de Servidor Multimedia (Plex)"

# 1. Validaciones
validate_root
ensure_package "curl"
ensure_package "apt-transport-https"
ensure_package "gpg"

# 2. Configuración del Repositorio Oficial
# Usamos el método moderno 'signed-by' compatible con Debian 11/12
REPO_FILE="/etc/apt/sources.list.d/plexmediaserver.list"
KEYRING="/usr/share/keyrings/plexmediaserver.gpg"

if [ ! -f "$REPO_FILE" ]; then
    log_info "Configurando repositorio oficial de Plex..."
    
    # Descarga de llave
    curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key | \
        gpg --dearmor | \
        execute_cmd "tee $KEYRING" > /dev/null
    
    # Configuración de fuente apt
    echo "deb [signed-by=$KEYRING] https://downloads.plex.tv/repo/deb public main" | \
        execute_cmd "tee $REPO_FILE" > /dev/null
        
    # Actualización de índices
    execute_cmd "apt-get update -qq" "Actualizando repositorios"
else
    log_info "Repositorio ya configurado."
fi

# 3. Instalación del Paquete
# APT gestionará las actualizaciones futuras automáticamente
ensure_package "plexmediaserver"

# 4. Integración con NAS (CRÍTICO)
log_info "Configurando permisos de acceso a medios..."

# Añadir plex al grupo 'media' permite leer /media/WDElements sin chmod 777
if ! id -nG "$PLEX_USER" | grep -qw "$MEDIA_GROUP"; then
    execute_cmd "usermod -aG $MEDIA_GROUP $PLEX_USER" "Añadiendo plex al grupo $MEDIA_GROUP"
else
    log_info "Usuario Plex ya pertenece al grupo $MEDIA_GROUP."
fi

# 5. Optimización Hardware (Raspberry Pi 4/5)
log_info "Habilitando aceleración por hardware (Transcoding)..."
# Grupos necesarios para acceder a /dev/dri y decodificadores video
for grp in video render; do
    if getent group "$grp" > /dev/null; then
        if ! id -nG "$PLEX_USER" | grep -qw "$grp"; then
            execute_cmd "usermod -aG $grp $PLEX_USER" "Añadiendo plex a $grp"
        fi
    fi
done

# 6. Gestión de Claim Token (Prudente)
if [ -n "$PLEX_CLAIM_TOKEN" ]; then
    # Solo informamos. La inyección automática es inestable en entornos nativos.
    log_info "Token de reclamación detectado en .env."
    log_info "Por seguridad, la reclamación se delega a la primera visita web."
fi

# 7. Arranque
# Restart necesario para aplicar nuevos grupos
log_info "Reiniciando servicio para aplicar permisos..."
execute_cmd "systemctl restart $SERVICE"
execute_cmd "systemctl enable $SERVICE"

# 8. Verificación Final
if check_service_active "$SERVICE"; then
    IP=$(hostname -I | awk '{print $1}')
    
    log_success "Plex Media Server instalado y activo."
    log_info "---------------------------------------------------"
    log_info "Web UI:     http://$IP:32400/web"
    log_info "Estado:     Servicio activo, repositorios configurados."
    log_info "IMPORTANTE: Si es la primera instalación, entra AHORA"
    log_info "            a la Web UI para reclamar el servidor."
    log_info "---------------------------------------------------"
    
    # Aviso de reinicio si es instalación fresca (a veces necesario por dbus/grupos)
    log_info "Si Plex no ve tus archivos inmediatamente, reinicia la Raspberry."
else
    log_error "Plex no arrancó. Revisa: 'journalctl -u $SERVICE'"
    exit 1
fi