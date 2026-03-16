#!/bin/bash
# scripts/30-services/webmin.sh
# Descripción: Instalación de Webmin (Panel de Administración) vía Repositorio Oficial
# Autor: Juan José Hipólito (Refactorizado para Confiraspa Framework)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# --- VARIABLES ---
readonly SERVICE="webmin"
readonly PORT="10000"
readonly REPO_URL="https://download.webmin.com/download/repository"
readonly KEY_URL="https://download.webmin.com/jcameron-key.asc"
readonly KEYRING="/usr/share/keyrings/webmin.gpg"
readonly REPO_FILE="/etc/apt/sources.list.d/webmin.list"

log_section "Instalación de Panel de Administración (Webmin)"

# 1. Validaciones
validate_root
ensure_package "curl"
ensure_package "gpg"
ensure_package "apt-transport-https"

# Dependencias de Perl que Webmin necesita para compilar sus módulos
# Instalarlas antes acelera el proceso y evita errores en apt
log_info "Pre-instalando dependencias de Perl..."
ensure_package "perl"
ensure_package "libnet-ssleay-perl"
ensure_package "openssl"
ensure_package "libauthen-pam-perl"
ensure_package "libpam-runtime"
ensure_package "libio-pty-perl"
ensure_package "python3"

# 2. Configuración del Repositorio (Método 'signed-by' moderno)
if [ ! -f "$REPO_FILE" ]; then
    log_info "Configurando repositorio oficial de Webmin..."
    
    # Descargar llave GPG y convertirla a formato keyring binario (más seguro que apt-key add)
    curl -fsSL "$KEY_URL" | gpg --dearmor | execute_cmd "tee $KEYRING" > /dev/null
    
    # Añadir fuente
    echo "deb [signed-by=$KEYRING] $REPO_URL sarge contrib" | execute_cmd "tee $REPO_FILE" > /dev/null
    
    # Actualizar índices
    execute_cmd "apt-get update -qq" "Actualizando lista de paquetes"
else
    log_info "Repositorio Webmin ya configurado."
fi

# 3. Instalación
# Webmin es grande, puede tardar un poco.
if ! dpkg -l | grep -q "webmin"; then
    log_info "Instalando paquete Webmin..."
    # -y para confirmar, install-recommends false para no meter basura
    execute_cmd "apt-get install -y --install-recommends webmin" "Instalación de Webmin"
else
    log_info "Webmin ya está instalado."
fi

# 4. Configuración Post-Instalación
log_info "Asegurando configuración..."

# Webmin a veces pierde el servicio systemd en instalaciones manuales antiguas,
# pero el paquete .deb oficial moderno lo maneja bien. Solo aseguramos el enable.
execute_cmd "systemctl enable $SERVICE"

# Reiniciar para asegurar que SSL y puertos estén frescos
execute_cmd "systemctl restart $SERVICE"

# 5. Verificación
if check_service_active "$SERVICE"; then
    IP=$(hostname -I | awk '{print $1}')
    HOSTNAME=$(hostname)
    
    log_success "Webmin instalado y operativo."
    log_info "---------------------------------------------------"
    log_info "Panel:      https://$IP:$PORT"
    log_info "Usuario:    ${SYS_USER:-root} (Tu usuario de sistema o root)"
    log_info "Contraseña: (Tu contraseña de sistema)"
    log_info "Nota:       Usa HTTPS. Acepta el certificado autofirmado."
    log_info "---------------------------------------------------"
else
    log_error "Webmin no arrancó. Revisa: 'systemctl status webmin'"
    exit 1
fi