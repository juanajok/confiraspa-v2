#!/bin/bash
# scripts/00-system/00-update.sh
# Descripción: Actualización del sistema y configuración de parches de seguridad automáticos
# Autor: Juan José Hipólito (Refactorizado para Confiraspa Framework)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

log_section "Actualización del Sistema y Parches de Seguridad"

# 1. Configuración No Interactiva
# Evita que apt pregunte "¿Quiere sobrescribir el archivo de config?"
export DEBIAN_FRONTEND=noninteractive

# 2. Actualización Manual Inicial (Bootstrap)
log_info "Actualizando repositorios y paquetes del sistema..."

# apt-get update
execute_cmd "apt-get update -qq" "Actualizando lista de paquetes"

# apt-get upgrade (Sin interacción)
# -o Dpkg::Options::="--force-confdef" -> Usa la config default si hay conflicto
# -o Dpkg::Options::="--force-confold" -> Conserva tu config vieja si la tocaste
APT_OPTS="-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
execute_cmd "apt-get upgrade $APT_OPTS" "Aplicando actualizaciones pendientes"
execute_cmd "apt-get dist-upgrade $APT_OPTS" "Aplicando actualizaciones de distribución"

# Limpieza
execute_cmd "apt-get autoremove -y" "Eliminando dependencias huérfanas"
execute_cmd "apt-get clean" "Limpiando caché de apt"


# =======================================================
# 3. CONFIGURACIÓN DE UNATTENDED-UPGRADES
# =======================================================
log_info "Configurando actualizaciones automáticas de seguridad..."

ensure_package "unattended-upgrades"
ensure_package "apt-listchanges"

# Detectar versión de Debian (bullseye, bookworm) para la config
DISTRO_CODENAME=$(lsb_release -sc)

# A. Archivo de Configuración de Orígenes (Qué actualizar)
# Lo escribimos en 52confiraspa-unattended para sobrescribir el 50-default
UNATTENDED_CONF="/etc/apt/apt.conf.d/52confiraspa-unattended"

log_info "Generando configuración en: $UNATTENDED_CONF"

# Heredoc con la configuración. Mucho más limpio que sed/grep.
cat <<EOF | execute_cmd "tee $UNATTENDED_CONF" > /dev/null
// Configuración Gestionada por Confiraspa
// Sobrescribe valores por defecto.

Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
    "Raspbian:\${distro_codename}";
    "Raspberry Pi Foundation:\${distro_codename}";
};

Unattended-Upgrade::Package-Blacklist {
    // Agrega paquetes aquí si quieres evitar que se actualicen solos
    // "docker-ce";
};

// Opciones de comportamiento
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false"; // Cambia a "true" si quieres reinicios a las 4am
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# B. Archivo de Configuración de Periodicidad (Cuándo actualizar)
# 20auto-upgrades suele ser el estándar
PERIODIC_CONF="/etc/apt/apt.conf.d/20auto-upgrades"

log_info "Configurando frecuencia diaria en: $PERIODIC_CONF"

cat <<EOF | execute_cmd "tee $PERIODIC_CONF" > /dev/null
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

# 4. Verificación
# Ejecutamos un dry-run de unattended-upgrades para asegurar que la config es válida
log_info "Verificando configuración de unattended-upgrades..."
if execute_cmd "unattended-upgrade --dry-run --debug" "Test de configuración"; then
    log_success "Sistema actualizado y actualizaciones automáticas configuradas."
else
    log_warning "Hubo una advertencia al probar unattended-upgrades. Revisa los logs."
    # No salimos con error 1 porque el sistema base sí se actualizó
fi