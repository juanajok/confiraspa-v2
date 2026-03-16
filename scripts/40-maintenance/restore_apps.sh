#!/bin/bash
# scripts/99-finalization/restore_apps.sh
# Descripción: Restauración selectiva de configuraciones con tolerancia a fallos
# Autor: Juan José Hipólito (Refactorizado v4 - Post Peer Review)

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
readonly CONFIG_FILE="$REPO_ROOT/configs/static/restore.json"
# Usuario/Grupo por defecto para los *Arr
readonly ARR_USER="${ARR_USER:-media}"
readonly ARR_GROUP="${ARR_GROUP:-media}"

log_section "Restauración de Configuraciones (Apps & Sistema)"

# 1. Validaciones
validate_root
ensure_package "jq"
ensure_package "unzip"

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Falta el archivo: $CONFIG_FILE"
    exit 1
fi

# 2. Bucle Principal (Iterar por claves del JSON)
APPS=$(jq -r 'keys[]' "$CONFIG_FILE")

for APP_KEY in $APPS; do
    log_subsection "Procesando: $APP_KEY"

    # Helper para extraer datos
    _jq() { jq -r ".\"$APP_KEY\".$1 // empty" "$CONFIG_FILE"; }

    BACKUP_DIR=$(_jq 'backup_dir')
    BACKUP_EXT=$(_jq 'backup_ext')
    RESTORE_DIR=$(_jq 'restore_dir')
    
    # Intentamos leer usuario/grupo del JSON. Si no existen, quedan vacíos.
    JSON_USER=$(_jq 'user')
    JSON_GROUP=$(_jq 'group')
    
    # --- DETERMINAR IDENTIDAD Y SERVICIO ---
    APP_LOWER="${APP_KEY,,}"
    SERVICE=""
    
    case "$APP_LOWER" in
        plex)
            SERVICE="plexmediaserver"
            TARGET_USER="${JSON_USER:-plex}"
            TARGET_GROUP="${JSON_GROUP:-$ARR_GROUP}"
            ;;
        rclone)
            SERVICE="" # Rclone no es un servicio, es config de usuario
            if [ -n "$JSON_USER" ]; then
                TARGET_USER="$JSON_USER"
                TARGET_GROUP="$JSON_GROUP"
            else
                # Heurística: Si restore_dir es /home/pi -> usuario pi. Si es /root -> root.
                if [[ "$RESTORE_DIR" == *"/home/"* ]]; then
                    # Extraer propietario del directorio padre (ej: /home/pi)
                    TARGET_USER=$(stat -c '%U' "$(dirname "$RESTORE_DIR")" 2>/dev/null || echo "${SUDO_USER:-pi}")
                    TARGET_GROUP=$(stat -c '%G' "$(dirname "$RESTORE_DIR")" 2>/dev/null || echo "${SUDO_USER:-pi}")
                else
                    TARGET_USER="root"
                    TARGET_GROUP="root"
                fi
            fi
            ;;
        *)
            # Por defecto: Suite *Arr
            SERVICE="$APP_LOWER"
            TARGET_USER="${JSON_USER:-$ARR_USER}"
            TARGET_GROUP="${JSON_GROUP:-$ARR_GROUP}"
            ;;
    esac

    log_info "Destino: $RESTORE_DIR ($TARGET_USER:$TARGET_GROUP)"

    # A. Detener Servicio (si existe y corre)
    if [ -n "$SERVICE" ] && check_service_active "$SERVICE"; then
        log_info "Deteniendo servicio $SERVICE..."
        execute_cmd "systemctl stop $SERVICE"
    fi

    # B. Crear directorio destino si falta
    if [ ! -d "$RESTORE_DIR" ]; then
        log_info "Creando directorio destino..."
        mkdir -p "$RESTORE_DIR"
    fi

    # C. Lógica de Restauración
    if [ "$BACKUP_EXT" == ".zip" ]; then
        # --- MODO ZIP (*Arr) ---
        
        LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/*"$BACKUP_EXT" 2>/dev/null | head -n 1)
        
        if [ -z "$LATEST_BACKUP" ]; then
            log_warning "No hay backups .zip en $BACKUP_DIR. Saltando."
            continue
        fi
        
        log_info "Usando backup: $(basename "$LATEST_BACKUP")"
        FILES_LIST=$(jq -r ".\"$APP_KEY\".files_to_restore[]" "$CONFIG_FILE")
        
        for FILE in $FILES_LIST; do
            # Extracción tolerante a fallos
            # unzip -j: junk paths (aplana estructura)
            # -o: overwrite (sobrescribe sin preguntar)
            if unzip -j -o "$LATEST_BACKUP" "$FILE" -d "$RESTORE_DIR" > /dev/null 2>&1; then
                log_info "  -> Restaurado: $FILE"
            else
                log_warning "  -> No se encontró '$FILE' dentro del ZIP. Omitido."
            fi
        done

    else
        # --- MODO ARCHIVO SUELTO (Plex/Rclone) ---
        
        FILES_LIST=$(jq -r ".\"$APP_KEY\".files_to_restore[]" "$CONFIG_FILE")
        
        for FILE in $FILES_LIST; do
            SRC_FILE="$BACKUP_DIR/$FILE"
            DEST_FILE="$RESTORE_DIR/$FILE"
            
            if [ -f "$SRC_FILE" ]; then
                cp "$SRC_FILE" "$DEST_FILE"
                log_info "  -> Copiado: $FILE"
            else
                log_warning "  -> Archivo origen no encontrado: $SRC_FILE"
            fi
        done
    fi

    # D. Aplicar Permisos Específicos (Del JSON)
    log_info "Ajustando permisos de archivos..."
    
    jq -r ".\"$APP_KEY\".file_permissions | to_entries[] | \"\(.key) \(.value)\"" "$CONFIG_FILE" | while read -r FILE PERM; do
        FULL_PATH="$RESTORE_DIR/$FILE"
        if [ -f "$FULL_PATH" ]; then
            chmod "$PERM" "$FULL_PATH"
            chown "$TARGET_USER:$TARGET_GROUP" "$FULL_PATH"
        fi
    done
    
    # Asegurar propiedad del directorio contenedor
    chown "$TARGET_USER:$TARGET_GROUP" "$RESTORE_DIR"

    # E. Arrancar Servicio
    if [ -n "$SERVICE" ]; then
        log_info "Iniciando $SERVICE..."
        execute_cmd "systemctl start $SERVICE"
    fi

done

log_success "Restauración completada."