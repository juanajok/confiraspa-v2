#!/bin/bash
# scripts/99-finalization/backup_rsync.sh
# Descripción: Motor de copias de seguridad incremental con protecciones de seguridad
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
readonly CONFIG_FILE="$REPO_ROOT/configs/static/backup_rsync.json"
# Opciones de Rsync:
# -a: Archive (preserva permisos, dueños, fechas)
# -v: Verbose
# -h: Human readable
# --delete: Borra en destino lo que no existe en origen (PELIGROSO si falla montaje)
# --stats: Estadísticas al final
RSYNC_OPTS="-avh --delete --stats"

log_section "Ejecución de Copias de Seguridad (Rsync)"

# 1. Validaciones
validate_root
ensure_package "rsync"
ensure_package "jq"

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "No se encuentra el archivo de definición de backups: $CONFIG_FILE"
    exit 1
fi

# 2. Procesamiento de Trabajos
# Leemos el JSON línea a línea (formato compacto)
jq -c '.jobs[]' "$CONFIG_FILE" | while read -r job; do
    
    # Extraer datos
    NAME=$(echo "$job" | jq -r '.name')
    SRC=$(echo "$job" | jq -r '.origen')
    DEST=$(echo "$job" | jq -r '.destino')
    
    log_subsection "Backup: $NAME"
    log_info "Origen:  $SRC"
    log_info "Destino: $DEST"

    # --- SAFETY CHECKS (CRÍTICO) ---
    
    # A. Existencia del Origen
    if [ ! -e "$SRC" ]; then
        log_error "El origen no existe: $SRC. Saltando trabajo para proteger destino."
        continue
    fi

    # B. Protección contra 'Disco Desmontado'
    # Si el origen es un punto de montaje (ej: /media/WDElements) y está vacío,
    # rsync --delete borraría todo el backup.
    # Verificamos si es un directorio y si está vacío.
    if [ -d "$SRC" ]; then
        if [ -z "$(ls -A "$SRC")" ]; then
            log_warning "El directorio origen está VACÍO: $SRC"
            log_warning "Esto podría indicar un fallo de montaje. Abortando este backup por seguridad."
            continue
        fi
    fi

    # 3. Preparación
    if [ ! -d "$DEST" ]; then
        log_info "Creando directorio destino..."
        mkdir -p "$DEST"
    fi

    # 4. Ejecución
    # Construimos el comando. 
    # Nota: Añadimos barra final / a SRC para copiar el CONTENIDO, no la carpeta en sí.
    # Manejo de Exclusiones (Opcional en el JSON)
    EXCLUDES=""
    # Si quisieras implementar excludes del JSON, requeriría un bucle extra.
    # Por simplicidad, aquí ejecutamos el rsync básico.
    
    # Usamos execute_cmd para tener logs y soporte dry-run
    # ${SRC%/}/ asegura que siempre tenga una barra al final para rsync
    # ${DEST%/}/ asegura barra al final
    
    CMD="rsync $RSYNC_OPTS \"${SRC%/}/\" \"${DEST%/}/\""
    
    log_info "Sincronizando..."
    if execute_cmd "$CMD"; then
        log_success "Backup '$NAME' completado."
    else
        log_error "Fallo en backup '$NAME'. Revisa los logs anteriores."
    fi

done

log_success "Proceso de copias de seguridad finalizado."
