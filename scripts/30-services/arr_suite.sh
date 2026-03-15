#!/bin/bash
# scripts/30-services/arr_suite.sh
# Descripción: Instalación unificada de la Suite *Arr con Health Checks
# Autor: Juan José Hipólito (Refactorizado v4 - Health Checks)

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
# Orden lógico: Prowlarr primero (Indexers) -> Luego los gestores de contenido
readonly APPS=("prowlarr" "radarr" "lidarr" "readarr" "whisparr")

# Rutas Base
readonly INSTALL_BASE="/opt"
readonly DATA_BASE="/var/lib"

# Identidad del Servicio (Definida en .env)
readonly USER_NAME="${ARR_USER:-media}"
readonly GROUP_NAME="${ARR_GROUP:-media}"

# --- TRAP DE LIMPIEZA ---
CURRENT_TEMP_FILE=""
cleanup() {
    if [ -n "$CURRENT_TEMP_FILE" ] && [ -f "$CURRENT_TEMP_FILE" ]; then
        rm -f "$CURRENT_TEMP_FILE"
    fi
}
trap cleanup EXIT

log_section "Instalación de Suite Multimedia *Arr"

# 1. Validaciones y Dependencias
validate_root

# Dependencias Comunes (.NET Core Native)
ensure_package "curl"
ensure_package "sqlite3"
ensure_package "libicu-dev"
ensure_package "libssl-dev"

# Dependencias Específicas
ensure_package "libchromaprint-tools"
ensure_package "mediainfo"

# 2. Verificación de Identidad
log_info "Verificando usuario de servicios ($USER_NAME)..."
if ! id "$USER_NAME" &>/dev/null; then
    log_error "El usuario '$USER_NAME' no existe. Ejecuta 'scripts/00-system/10-users.sh' primero."
    exit 1
fi

# 3. Función Core (DRY)
install_arr_app() {
    local app_name="$1"
    local app_camel="${app_name^}" # Capitalización: radarr -> Radarr
    local install_dir="$INSTALL_BASE/$app_camel"
    local bin_file="$install_dir/$app_camel"
    local data_dir="$DATA_BASE/$app_name"
    
    # Metadatos por App (Puerto y Rama)
    local port branch
    case "$app_name" in
        prowlarr) port="9696"; branch="develop" ;;
        radarr)   port="7878"; branch="master" ;;
        lidarr)   port="8686"; branch="master" ;;
        readarr)  port="8787"; branch="develop" ;;
        whisparr) port="6969"; branch="nightly" ;;
        *)        log_error "App desconocida: $app_name"; return 1 ;;
    esac

    log_subsection "Procesando: $app_camel"

    # A. Instalación de Binarios (Idempotencia)
    if [ -x "$bin_file" ]; then
        log_info "$app_camel ya está instalado."
        log_info "Saltando descarga (Modo Idempotente / No-Upgrade)."
    else
        log_info "Iniciando instalación limpia (Rama: $branch)..."
        
        # Detectar Arquitectura
        local arch
        case "$(dpkg --print-architecture)" in
            amd64) arch="x64" ;;
            arm64) arch="arm64" ;;
            armhf) arch="arm" ;;
            *) log_error "Arquitectura no soportada"; return 1 ;;
        esac

        # Descarga
        local dl_url="https://$app_name.servarr.com/v1/update/$branch/updatefile?os=linux&runtime=netcore&arch=$arch"
        CURRENT_TEMP_FILE="/tmp/${app_name}.tar.gz"

        execute_cmd "curl -sL -o $CURRENT_TEMP_FILE '$dl_url'" "Descargando binarios"
        
        # Limpieza directorio previo
        if [ -d "$install_dir" ]; then rm -rf "$install_dir"; fi
        mkdir -p "$install_dir"

        # Extracción
        execute_cmd "tar -xzf $CURRENT_TEMP_FILE -C $install_dir --strip-components=1"
        rm -f "$CURRENT_TEMP_FILE"
        CURRENT_TEMP_FILE=""

        # Permisos Binarios
        execute_cmd "chown -R $USER_NAME:$GROUP_NAME $install_dir"
    fi

    # B. Directorio de Datos (Anti-Drift de Permisos)
    if [ ! -d "$data_dir" ]; then mkdir -p "$data_dir"; fi
    
    execute_cmd "chown -R $USER_NAME:$GROUP_NAME $data_dir"
    execute_cmd "chmod 775 $data_dir"

    # C. Servicio Systemd (Hardened)
    local service_file="/etc/systemd/system/$app_name.service"
    
    cat <<EOF | execute_cmd "tee $service_file" > /dev/null
[Unit]
Description=$app_camel Daemon (Native)
After=network.target

[Service]
User=$USER_NAME
Group=$GROUP_NAME
UMask=0002
Type=simple
ExecStart=$bin_file -nobrowser -data=$data_dir
TimeoutStopSec=20
KillMode=process
Restart=on-failure

# Security Hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    # D. Arranque
    execute_cmd "systemctl daemon-reload"
    
    if systemctl is-active --quiet "$app_name"; then
        log_info "Servicio $app_name activo. Reiniciando para aplicar cambios..."
        execute_cmd "systemctl restart $app_name"
    else
        execute_cmd "systemctl enable --now $app_name" "Iniciando servicio"
    fi

    # E. Verificación y Health Check (NUEVO)
    # Primero verificamos que systemd cree que el proceso corre
    if systemctl is-active --quiet "$app_name"; then
        
        # AHORA verificamos que el puerto TCP responde realmente
        # Usamos la función de utils.sh
        if wait_for_service "localhost" "$port" "$app_camel"; then
            local ip=$(hostname -I | awk '{print $1}')
            log_success "$app_camel instalado y respondiendo."
            log_info "---------------------------------------------------"
            log_info "URL:        http://$ip:$port"
            log_info "Datos:      $data_dir"
            log_info "---------------------------------------------------"
        else
            log_error "$app_camel está activo pero NO responde en el puerto $port."
            log_error "Posible fallo de inicio en .NET. Revisa logs."
            exit 1
        fi
    else
        log_error "El servicio $app_name falló al iniciar. Revisa: 'journalctl -u $app_name'"
        exit 1
    fi
}

# 4. Loop Principal
for app in "${APPS[@]}"; do
    install_arr_app "$app"
done

log_section "Instalación de Suite Completa Finalizada."