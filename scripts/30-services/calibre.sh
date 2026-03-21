#!/usr/bin/env bash
# scripts/30-services/calibre.sh
# Descripción: Instalación de Calibre Server (Oficial) alineada con arquitectura 64-bit
# Autor: Juan José Hipólito (Refactorizado v5.2 - Path Fix)

set -euo pipefail
IFS=$'\n\t'

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"

# Cargar .env si no estamos bajo install.sh (ej: --only calibre)
if [[ -f "$REPO_ROOT/.env" ]]; then
    source "$REPO_ROOT/.env"
fi

# --- CONSTANTES ---
readonly SERVICE="calibre-server"
readonly BASE_DIR="/opt/calibre"                 # Carpeta raíz de la app
readonly INSTALL_DIR="/opt/calibre/calibre"      # Carpeta donde cae el binario tras isolated=y
readonly CALIBRE_USER="calibre"
readonly MEDIA_GROUP="${ARR_GROUP:-media}"
readonly PORT="8080"
readonly LIBRARY_PATH="${DIR_BOOKS:-/media/WDElements/Libros}"

log_section "Instalación de Servidor de eBooks (Calibre)"

# 1. Validaciones de Sistema
validate_root
require_system_commands install systemctl id getent awk grep mkdir chown chmod wget cat

# 2. Gestión de Usuario
log_info "Configurando identidad del servicio..."

if ! id "$CALIBRE_USER" &>/dev/null; then
    execute_cmd "useradd --system --shell /bin/false --home-dir /var/lib/calibre $CALIBRE_USER" "Creando usuario calibre"
fi

if [[ "${DRY_RUN:-false}" == "false" ]]; then
    assert_system_state "getent group '$MEDIA_GROUP'" "El grupo '$MEDIA_GROUP' no existe. Ejecuta 10-users.sh primero."
    
    if ! id -nG "$CALIBRE_USER" | grep -qw "$MEDIA_GROUP"; then
        execute_cmd "usermod -aG $MEDIA_GROUP $CALIBRE_USER" "Integrando usuario en grupo $MEDIA_GROUP"
    fi
else
    log_warning "[DRY-RUN] Saltando validación de usuarios."
fi

# 3. Instalación de Binarios (Oficial)
# Chequeamos la ruta real corregida: /opt/calibre/calibre/calibre-server
if [ -x "$INSTALL_DIR/calibre-server" ]; then
    log_info "Calibre ya está instalado en $INSTALL_DIR. Saltando descarga."
else
    log_info "Iniciando descarga e instalación (Latest)..."

    if [[ "${DRY_RUN:-false}" == "false" ]]; then
        mkdir -p "$BASE_DIR"
        
        # El instalador con isolated=y crea automáticamente la subcarpeta /calibre/
        execute_cmd "wget -nv -O- https://download.calibre-ebook.com/linux-installer.sh | sh /dev/stdin install_dir=$BASE_DIR isolated=y" "Ejecutando instalador oficial de Calibre"

        if [ ! -x "$INSTALL_DIR/calibre-server" ]; then
            log_error "La instalación falló: el binario no aparece en la ruta esperada."
            log_error "Ruta buscada: $INSTALL_DIR/calibre-server"
            exit 1
        fi
        log_success "Binarios de Calibre instalados correctamente."
    else
        log_warning "[DRY-RUN] Simulación de instalación completada."
    fi
fi

# 4. Configuración de Biblioteca y Permisos NAS
log_info "Configurando biblioteca en: $LIBRARY_PATH"

if [ ! -d "$LIBRARY_PATH" ]; then
    execute_cmd "mkdir -p $LIBRARY_PATH" "Creando carpeta de biblioteca"
fi

execute_cmd "chown -R $CALIBRE_USER:$MEDIA_GROUP $LIBRARY_PATH" "Asignando propietario a la biblioteca"
execute_cmd "chmod -R 775 $LIBRARY_PATH" "Ajustando permisos 775"
execute_cmd "chmod g+s $LIBRARY_PATH" "Activando SetGID para herencia de grupo"

# 5. Generación de servicio Systemd
SERVICE_FILE="/etc/systemd/system/$SERVICE.service"
log_info "Configurando unidad de servicio..."

if [[ "${DRY_RUN:-false}" == "false" ]]; then
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Calibre Content Server
After=network.target

[Service]
Type=simple
User=$CALIBRE_USER
Group=$MEDIA_GROUP
UMask=0002
ExecStart=$INSTALL_DIR/calibre-server --port $PORT --enable-local-write "$LIBRARY_PATH"
Restart=on-failure
RestartSec=10

# Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    log_success "Archivo .service generado correctamente."
else
    log_warning "[DRY-RUN] Omitiendo creación de archivo systemd."
fi

# 6. Arranque y Habilitación
execute_cmd "systemctl daemon-reload" "Recargando demonios de systemd"

if check_service_active "$SERVICE"; then
    log_info "Servicio ya en ejecución. Reiniciando para aplicar cambios..."
    execute_cmd "systemctl restart $SERVICE" "Reiniciando $SERVICE"
else
    execute_cmd "systemctl enable --now $SERVICE" "Habilitando e iniciando $SERVICE"
fi

# 7. Verificación final (Health Check)
if check_service_active "$SERVICE"; then
    IP=$(hostname -I | awk '{print $1}')
    log_success "¡Calibre Server está operativo!"
    log_info "---------------------------------------------------"
    log_info "URL Acceso:  http://$IP:$PORT"
    log_info "Biblioteca:  $LIBRARY_PATH"
    log_info "Binarios en: $INSTALL_DIR"
    log_info "---------------------------------------------------"
else
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_success "[DRY-RUN] Simulación finalizada."
    else
        log_error "El servicio no pudo arrancar."
        exit 1
    fi
fi