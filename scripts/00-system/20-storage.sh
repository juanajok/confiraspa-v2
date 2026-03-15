#!/bin/bash
# scripts/00-system/20-storage.sh
# Descripción: Monta discos, crea estructura de directorios y corrige permisos para la Suite *Arr
# Autor: Juan José Hipólito (Refactorizado para Confiraspa Framework)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
# Detecta automáticamente la raíz del repositorio
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
# Carga librerías y variables de entorno (.env)
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"
# --------------------------

# Configuración interna
CONFIG_FILE="$REPO_ROOT/configs/static/mounts.json"
FSTAB="/etc/fstab"

# Variables de usuario (con fallback por seguridad)
ARR_USER="${ARR_USER:-media}"
ARR_GROUP="${ARR_GROUP:-media}"

log_section "Configuración de Almacenamiento y Permisos"

# 1. Validaciones Previas
validate_root
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Archivo de configuración no encontrado: $CONFIG_FILE"
    exit 1
fi
# Necesitamos jq para leer el JSON
ensure_package "jq"

# 2. Backup de seguridad de fstab
# Siempre es bueno tener un respaldo antes de tocar archivos de sistema críticos
if [ ! -f "${FSTAB}.bak" ]; then
    execute_cmd "cp $FSTAB ${FSTAB}.bak" "Creando backup de fstab"
fi

# 3. Procesamiento de Montajes (mounts.json)
log_info "Leyendo configuración de discos..."

# Leemos el JSON en base64 para manejar espacios o caracteres raros en las etiquetas
for row in $(jq -r '.puntos_de_montaje[] | @base64' "$CONFIG_FILE"); do
    _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }

    LABEL=$(_jq '.label')
    UUID=$(_jq '.uuid')
    MOUNT_POINT=$(_jq '.ruta')
    FSTYPE=$(_jq '.fstype')
    OPTS=$(_jq '.opciones')

    log_info "Procesando disco: $LABEL ($UUID)"

    # A. Crear directorio de montaje (punto de anclaje)
    if [ ! -d "$MOUNT_POINT" ]; then
        execute_cmd "mkdir -p $MOUNT_POINT" "Creando punto de montaje $MOUNT_POINT"
    fi

    # B. Idempotencia: Solo añadir a fstab si no existe ya
    if grep -q "$UUID" "$FSTAB"; then
        log_warning "  -> El UUID $UUID ya existe en fstab. Saltando."
    else
        log_info "  -> Añadiendo entrada a fstab..."
        # Escribimos la línea estándar de fstab
        echo "UUID=$UUID  $MOUNT_POINT  $FSTYPE  $OPTS  0  2" | execute_cmd "tee -a $FSTAB"
    fi
done

# 4. Aplicar Cambios de Montaje
log_info "Recargando sistema de archivos..."
execute_cmd "systemctl daemon-reload"
execute_cmd "mount -a" # Monta todo lo que esté en fstab y no esté montado

# =======================================================
# 5. ESTRUCTURA DE CARPETAS Y PERMISOS (CRÍTICO)
# =======================================================
log_section "Estandarización de Permisos ($ARR_USER:$ARR_GROUP)"

# A. Asegurar que el usuario y grupo 'media' existen
if ! getent group "$ARR_GROUP" > /dev/null; then
    execute_cmd "groupadd $ARR_GROUP" "Creando grupo $ARR_GROUP"
fi
if ! id -u "$ARR_USER" > /dev/null 2>&1; then
    execute_cmd "useradd -r -s /bin/false -g $ARR_GROUP $ARR_USER" "Creando usuario sistema $ARR_USER"
fi

# B. Definir directorios objetivo
# Usamos sintaxis defensiva: ${VARIABLE:-default}
# Si el .env falla, se usan las rutas por defecto de tu estructura WDElements/DiscoDuro
TARGET_DIRS=(
    "${DIR_SERIES:-/media/WDElements/Series}"
    "${DIR_MOVIES:-/media/WDElements/Peliculas}"
    "${DIR_MUSIC:-/media/WDElements/Musica}"       # Para Lidarr
    "${DIR_BOOKS:-/media/WDElements/Libros}"       # Para Readarr
    "${DIR_TORRENTS:-/media/DiscoDuro/downloads}"  # Cache de descarga
)

# C. Aplicar permisos recursivos
for DIR in "${TARGET_DIRS[@]}"; do
    # Crear carpeta si no existe
    if [ ! -d "$DIR" ]; then
        log_info "Creando directorio faltante: $DIR"
        execute_cmd "mkdir -p $DIR"
    fi
    
    # Asignar dueño y permisos
    # 775 = Dueño(RWX) Grupo(RWX) Otros(RX) -> El grupo 'media' puede escribir/borrar
    log_info "Corrigiendo permisos en: $DIR"
    execute_cmd "chown -R $ARR_USER:$ARR_GROUP $DIR"
    execute_cmd "chmod -R 775 $DIR"
done

log_success "Discos montados y estructura de carpetas configurada correctamente."