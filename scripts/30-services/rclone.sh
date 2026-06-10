#!/bin/bash
# scripts/30-services/rclone.sh
# Descripción: Instalación de Rclone con soporte FUSE3 y restauración de config
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

# --- VARIABLES ---
readonly RCLONE_CONFIG_DIR="/root/.config/rclone"
readonly RCLONE_CONF_FILE="$RCLONE_CONFIG_DIR/rclone.conf"
readonly REPO_CONFIG_BACKUP="$REPO_ROOT/configs/legacy/rclone.conf" 
readonly FUSE_CONF="/etc/fuse.conf"

log_section "Instalación de Herramienta Cloud (Rclone)"

# 1. Validaciones
validate_root

# 2. Instalación de FUSE (Crítico para 'rclone mount')
log_info "Configurando soporte FUSE (File System in User Space)..."
ensure_package "fuse3"

# Configuración robusta de 'user_allow_other'
# Esto permite que servicios como Plex (no-root) lean montajes hechos por Rclone
if grep -q "^user_allow_other" "$FUSE_CONF"; then
    log_info "Opción 'user_allow_other' ya activa en $FUSE_CONF."
else
    if grep -q "^#user_allow_other" "$FUSE_CONF"; then
        log_info "Habilitando 'user_allow_other' (descomentando)..."
        execute_cmd "sed -i 's/^#user_allow_other/user_allow_other/' $FUSE_CONF"
    else
        log_info "Añadiendo 'user_allow_other' a $FUSE_CONF..."
        echo "user_allow_other" | execute_cmd "tee -a $FUSE_CONF"
    fi
fi

# 3. Instalación de Rclone (Idempotente)
# SECURITY: El instalador curl|bash oficial ejecuta código remoto sin verificación
# de integridad. Se usa el paquete del repo Debian, que viene firmado con la clave
# APT del proyecto y es auditado por los mantenedores de la distribución.
log_info "Instalando rclone desde repositorio Debian..."
ensure_package "rclone"

# 4. Gestión de Configuración (Restauración Segura)
if [ ! -d "$RCLONE_CONFIG_DIR" ]; then
    log_info "Creando directorio de configuración..."
    execute_cmd "mkdir -p $RCLONE_CONFIG_DIR" "Creando directorio de configuración rclone"
    # SECURITY: Solo root puede entrar — el directorio contiene tokens de acceso cloud.
    execute_cmd "chmod 700 $RCLONE_CONFIG_DIR" "Restringiendo permisos del directorio rclone"
fi

# Estrategia de Restauración
if [ -f "$REPO_CONFIG_BACKUP" ]; then
    log_info "Backup detectado en repositorio ($REPO_CONFIG_BACKUP)."
    
    if [ ! -f "$RCLONE_CONF_FILE" ]; then
        log_info "Restaurando rclone.conf..."
        execute_cmd "cp $REPO_CONFIG_BACKUP $RCLONE_CONF_FILE"
        # Permisos 600: Solo el dueño puede leer el archivo (contiene tokens)
        execute_cmd "chmod 600 $RCLONE_CONF_FILE"
    else
        log_warning "Ya existe una configuración en el sistema. Se conserva la actual."
    fi
else
    log_info "No hay backup de configuración para restaurar."
fi

# 5. Verificación Final
# En modo simulación (dry-run), asumimos que la instalación habría tenido éxito.
if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_success "[DRY-RUN] Simulación de instalación de Rclone completada."
    log_info "Saltando validación de remotos configurados (archivo no escrito)."
else
    # Ejecución real
    if command -v rclone &> /dev/null; then
        log_success "Rclone instalado correctamente."
        
        # CORRECCIÓN: Asegúrate de que haya un espacio después del 'if' aquí:
        if [ -f "$RCLONE_CONF_FILE" ]; then
            log_info "Remotos configurados:"
            rclone listremotes --config="$RCLONE_CONF_FILE" | sed 's/^/  - /'
        else
            log_warning "Rclone no tiene configuración activa."
            log_info "Ejecuta 'rclone config' para añadir Google Drive, Dropbox, etc."
        fi
    else
        log_error "La instalación de Rclone falló."
        exit 1
    fi
fi