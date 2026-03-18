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
ensure_package "curl"
ensure_package "unzip"
ensure_package "man-db" 

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
        # Usamos tee -a para añadir al final de forma segura con sudo
        echo "user_allow_other" | execute_cmd "tee -a $FUSE_CONF"
    fi
fi

# 3. Instalación de Rclone (Idempotente)
if command -v rclone &> /dev/null; then
    VERSION=$(rclone --version | head -n 1)
    log_success "Rclone ya está instalado: $VERSION"
else
    log_info "Descargando instalador oficial..."
    INSTALLER="/tmp/rclone_install.sh"
    
    # Descarga trazeada
    execute_cmd "curl -fsSL https://rclone.org/install.sh -o $INSTALLER" "Descarga completada"
    
    # Ejecución
    execute_cmd "bash $INSTALLER" "Instalando binarios Rclone"
    rm -f "$INSTALLER"
fi

# 4. Gestión de Configuración (Restauración Segura)
if [ ! -d "$RCLONE_CONFIG_DIR" ]; then
    log_info "Creando directorio de configuración..."
    mkdir -p "$RCLONE_CONFIG_DIR"
    # Permisos 700: Solo root puede entrar aquí (Seguridad Premium)
    chmod 700 "$RCLONE_CONFIG_DIR"
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