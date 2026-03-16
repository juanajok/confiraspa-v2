#!/bin/bash
# scripts/10-network/20-vnc.sh
# Descripción: Habilita RealVNC y fuerza resolución 720p para modo Headless
# Autor: Juan José Hipólito (Refactorizado para Confiraspa Framework)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

log_section "Configuración de VNC (RealVNC)"

# 1. Detección del archivo de configuración (Bookworm vs Legacy)
if [ -f "/boot/firmware/config.txt" ]; then
    CONFIG_FILE="/boot/firmware/config.txt"
elif [ -f "/boot/config.txt" ]; then
    CONFIG_FILE="/boot/config.txt"
elif [[ "${DRY_RUN:-false}" == "true" ]]; then
    # MEJORA: Si es dry-run y no estamos en una Pi, simulamos el archivo
    log_warning "[DRY-RUN] Entorno no-RPi detectado. Simulando archivo de configuración."
    CONFIG_FILE="/tmp/config.txt.sim"
    touch "$CONFIG_FILE"
else
    log_error "No se encontró config.txt en /boot ni /boot/firmware. ¿Es Raspberry Pi OS?"
    exit 1
fi
log_info "Archivo de configuración detectado: $CONFIG_FILE"

# 2. Instalación de RealVNC
# El servicio vncserver-x11-serviced pertenece al paquete realvnc-vnc-server
ensure_package "realvnc-vnc-server"

# 3. Configuración de Resolución (Headless Mode)
# Objetivo: 1280x720 (Group 2, Mode 85) + Force Hotplug
log_info "Configurando resolución forzada (720p) para modo sin monitor..."

# A. Backup de seguridad
if [ ! -f "${CONFIG_FILE}.bak" ]; then
    execute_cmd "cp $CONFIG_FILE ${CONFIG_FILE}.bak" "Creando backup de config.txt"
fi

# B. Modificación Idempotente
# Usamos una función helper interna para no repetir lógica
set_config_var() {
    local key="$1"
    local value="$2"
    local file="$3"
    
    if grep -q "^$key=" "$file"; then
        # Si existe, lo cambiamos (sed inplace)
        # Solo lo cambiamos si el valor es diferente
        if ! grep -q "^$key=$value" "$file"; then
            log_info "Actualizando $key a $value"
            execute_cmd "sed -i 's/^$key=.*/$key=$value/' $file"
        fi
    else
        # Si no existe, lo añadimos
        log_info "Añadiendo $key=$value"
        echo "$key=$value" | execute_cmd "tee -a $file"
    fi
}

# Aplicar las configuraciones
# hdmi_force_hotplug=1 es VITAL para que VNC funcione sin cable HDMI conectado
set_config_var "hdmi_force_hotplug" "1" "$CONFIG_FILE"
set_config_var "hdmi_group" "2" "$CONFIG_FILE"
set_config_var "hdmi_mode" "85" "$CONFIG_FILE"

# 4. Gestión del Servicio
SERVICE="vncserver-x11-serviced.service"

log_info "Gestionando servicio VNC..."

if check_service_active "$SERVICE"; then
    log_success "El servicio VNC ya está corriendo."
else
    execute_cmd "systemctl unmask $SERVICE" || true # Por si acaso estaba enmascarado
    execute_cmd "systemctl enable $SERVICE" "Habilitando servicio al inicio"
    execute_cmd "systemctl start $SERVICE" "Iniciando servicio ahora"
fi

# 5. Información Final
CURRENT_IP=$(hostname -I | awk '{print $1}')
log_success "VNC Configurado."
log_info "Resolución forzada: 1280x720 (Requiere reinicio para aplicar cambios de vídeo)."
log_info "Conéctate a: $CURRENT_IP:5900"
