#!/bin/bash
# scripts/00-system/10-users.sh
# Descripción: Gestión de usuarios del sistema, grupos y permisos sudo.
# Autor: Juan José Hipólito (Refactorizado para Confiraspa Framework)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

log_section "Configuración de Usuarios y Grupos"

# 1. Cargar configuración del .env (con defaults seguros)
# Estas variables vienen del .env global
TARGET_USER="${SYS_USER:-pi}"
TARGET_PASS="${SYS_PASSWORD:-}"
SHARED_GROUP="${ARR_GROUP:-media}"

validate_root

# 2. Configurar el Grupo Compartido (Media)
# Este grupo es vital para que tú, Sonarr, Samba y Plex se entiendan.
if ! getent group "$SHARED_GROUP" > /dev/null; then
    log_info "Creando grupo compartido: $SHARED_GROUP"
    execute_cmd "groupadd $SHARED_GROUP"
else
    log_info "Grupo '$SHARED_GROUP' ya existe."
fi

# 3. Configurar el Usuario del Sistema
if id "$TARGET_USER" &>/dev/null; then
    log_info "El usuario '$TARGET_USER' ya existe."
else
    log_info "Creando usuario del sistema: $TARGET_USER"
    # -m: Crear home, -s: Shell bash, -G: Grupos iniciales
    execute_cmd "useradd -m -s /bin/bash -G sudo,video,users $TARGET_USER"
fi

# 4. Configurar Contraseña (Idempotente y Seguro)
# Solo cambiamos la contraseña si está definida en .env y no es la default del ejemplo
if [[ -n "$TARGET_PASS" && "$TARGET_PASS" != "ChangeMeImmediately!" ]]; then
    log_info "Actualizando contraseña para $TARGET_USER..."
    # Usamos chpasswd que es más seguro para scripts que 'passwd'
    echo "$TARGET_USER:$TARGET_PASS" | execute_cmd "chpasswd" "Aplicando contraseña"
else
    log_warning "No se ha definido SYS_PASSWORD en .env o es la default. Se mantiene la contraseña actual."
fi

# 5. Asignar Grupos Adicionales
log_info "Añadiendo '$TARGET_USER' a grupos necesarios..."

# Lista de grupos a los que debe pertenecer el admin
GROUPS_TO_ADD=("sudo" "video" "users" "$SHARED_GROUP")

for group in "${GROUPS_TO_ADD[@]}"; do
    # Verificar si el grupo existe en el sistema antes de añadir
    if getent group "$group" > /dev/null; then
        # Verificar si el usuario ya está en el grupo
        if ! id -nG "$TARGET_USER" | grep -qw "$group"; then
            execute_cmd "usermod -aG $group $TARGET_USER" "Añadiendo a grupo: $group"
        fi
    else
        log_warning "El grupo '$group' no existe en el sistema. Omitiendo."
    fi
done

# 6. Permisos Sudo sin contraseña (Opcional - Configurable)
# Esto es útil para automatización, pero evalúa si lo quieres.
# Por defecto en Raspberry Pi OS, el grupo sudo ya tiene esto o pide pass.
# Descomenta si quieres forzar sudo sin password:
# echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" | execute_cmd "tee /etc/sudoers.d/010_$TARGET_USER-nopasswd"

log_success "Configuración de usuarios finalizada."
log_info "NOTA: Si has cambiado tus propios grupos, necesitarás cerrar sesión y volver a entrar."