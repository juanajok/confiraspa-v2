#!/bin/bash
# scripts/10-network/10-xrdp.sh
# Descripción: Instalación de servidor de Escritorio Remoto (RDP)
# Autor: Juan José Hipólito (Refactorizado para Confiraspa Framework)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

log_section "Configuración de Acceso Remoto (XRDP)"

# 1. Validación de Entorno (Fail Fast)
# XRDP necesita un entorno gráfico (X11). Si es una instalación Lite/Headless, avisamos.
if ! dpkg -l | grep -q "xserver-xorg-core"; then
    log_warning "No se detectó entorno gráfico (X Server). XRDP podría no funcionar en versiones Lite."
    log_warning "Si deseas continuar, asegúrate de instalar un escritorio (ej: raspberry-pi-ui-mods)."
    # No salimos con exit 1 para no romper la cadena si el usuario sabe lo que hace,
    # pero dejamos el aviso claro.
fi

# 2. Idempotencia: Verificar instalación
if check_service_active xrdp; then
    log_success "XRDP ya está instalado y ejecutándose."
    exit 0
fi

# 3. Instalación
log_info "Instalando paquete xrdp..."
execute_cmd "apt-get install -y xrdp" "Instalación de binarios"

# 4. CORRECCIÓN CRÍTICA PARA RASPBERRY PI / DEBIAN
# El usuario xrdp necesita acceso a los certificados ssl-cert, o fallará al conectar.
log_info "Aplicando corrección de permisos SSL (xrdp -> ssl-cert)..."
if ! id -nG xrdp | grep -qw "ssl-cert"; then
    execute_cmd "adduser xrdp ssl-cert" "Añadiendo usuario xrdp al grupo ssl-cert"
fi

# 5. Configuración de Inicio (Systemd)
# Reiniciamos el servicio para asegurar que pille los nuevos permisos de grupo
execute_cmd "systemctl restart xrdp" "Reiniciando servicio"
execute_cmd "systemctl enable xrdp" "Habilitando inicio automático"

# 6. Información útil al usuario
# Obtenemos la IP para mostrarla
CURRENT_IP=$(hostname -I | awk '{print $1}')
log_success "Escritorio remoto instalado."
log_info "Conéctate usando 'Escritorio Remoto de Windows' a: $CURRENT_IP"
log_info "Usuario: ${SYS_USER:-pi}"
log_info "Contraseña: (Tu contraseña de sistema)"