#!/bin/bash
# scripts/40--maintenance/logrotate.sh
# Descripción: Gestión integral de logs (Sistema + JSON Parser Mejorado)
# Autor: Juan José Hipólito (Refactorizado v4 - JSON Boolean Support)

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
readonly JSON_CONFIG="$REPO_ROOT/configs/static/logrotate_jobs.json"
readonly TARGET_FILE="/etc/logrotate.d/confiraspa-dynamic"
readonly GLOBAL_CONF="/etc/logrotate.conf"
readonly JOURNAL_CONF="/etc/systemd/journald.conf"

log_section "Optimización de Logs (Logrotate + Journal)"

# 1. Validaciones
validate_root
ensure_package "logrotate"
ensure_package "jq"

# 2. Optimización Global del Sistema (Mantenimiento)
log_info "Optimizando configuración global (compress)..."
if grep -q "^#compress" "$GLOBAL_CONF"; then
    execute_cmd "sed -i 's/^#compress/compress/' $GLOBAL_CONF"
fi

# Limitar Journald a 100MB (Salvavidas de SD)
log_info "Limitando Systemd Journal a 100MB..."
if grep -q "^#SystemMaxUse=" "$JOURNAL_CONF" || grep -q "^SystemMaxUse=" "$JOURNAL_CONF"; then
    execute_cmd "sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=100M/' $JOURNAL_CONF"
    execute_cmd "sed -i 's/^SystemMaxUse=.*/SystemMaxUse=100M/' $JOURNAL_CONF"
else
    echo "SystemMaxUse=100M" | execute_cmd "tee -a $JOURNAL_CONF"
fi
execute_cmd "systemctl restart systemd-journald"

# 3. Generación Dinámica desde JSON
log_info "Procesando reglas desde $JSON_CONFIG..."

if [ ! -f "$JSON_CONFIG" ]; then
    log_warning "No se encontró archivo JSON. Saltando generación dinámica."
else
    # Archivo temporal para validación atómica
    TEMP_CONF=$(mktemp)
    
    echo "# Configuración generada por Confiraspa" > "$TEMP_CONF"
    echo "# NO EDITAR MANUALMENTE - Modificar configs/static/logrotate_jobs.json" >> "$TEMP_CONF"
    echo "" >> "$TEMP_CONF"

    # Procesar JSON
    jq -c '.jobs[]' "$JSON_CONFIG" | while read -r job; do
        NAME=$(echo "$job" | jq -r '.name')
        PATH=$(echo "$job" | jq -r '.path')
        ROTATE=$(echo "$job" | jq -r '.rotate // 7')
        
        # Detección inteligente de Frecuencia (Boolean o String)
        IS_DAILY=$(echo "$job" | jq -r '.daily // false')
        IS_WEEKLY=$(echo "$job" | jq -r '.weekly // false')
        FREQ_STR=$(echo "$job" | jq -r '.frequency // empty')

        if [ "$IS_DAILY" == "true" ]; then FREQ="daily";
        elif [ "$IS_WEEKLY" == "true" ]; then FREQ="weekly";
        elif [ -n "$FREQ_STR" ]; then FREQ="$FREQ_STR";
        else FREQ="daily"; fi # Default

        # Booleanos
        COMPRESS=$(echo "$job" | jq -r '.compress // true')
        MISSINGOK=$(echo "$job" | jq -r '.missingok // true')
        NOTIFEMPTY=$(echo "$job" | jq -r '.notifempty // true')
        COPYTRUNCATE=$(echo "$job" | jq -r '.copytruncate // false')
        
        # Strings Opcionales
        CREATE=$(echo "$job" | jq -r '.create // empty')
        POSTROTATE=$(echo "$job" | jq -r '.postrotate // empty')

        log_info "  -> Generando regla: $NAME ($FREQ)"

        # Escribir bloque en formato Logrotate
        {
            echo "$PATH {"
            echo "    $FREQ"
            echo "    rotate $ROTATE"
            [ "$COMPRESS" == "true" ] && echo "    compress" && echo "    delaycompress"
            [ "$MISSINGOK" == "true" ] && echo "    missingok"
            [ "$NOTIFEMPTY" == "true" ] && echo "    notifempty"
            [ "$COPYTRUNCATE" == "true" ] && echo "    copytruncate"
            
            if [ -n "$CREATE" ]; then
                echo "    create $CREATE"
            fi
            
            if [ -n "$POSTROTATE" ]; then
                echo "    sharedscripts"
                echo "    postrotate"
                echo "        $POSTROTATE"
                echo "    endscript"
            fi
            echo "}"
            echo ""
        } >> "$TEMP_CONF"
    done

    # 4. Validación y Aplicación
    log_info "Verificando sintaxis generada..."
    if logrotate -d "$TEMP_CONF" > /dev/null 2>&1; then
        execute_cmd "mv $TEMP_CONF $TARGET_FILE"
        execute_cmd "chmod 644 $TARGET_FILE"
        execute_cmd "chown root:root $TARGET_FILE"
        log_success "Reglas aplicadas correctamente en $TARGET_FILE"
    else
        log_error "La configuración generada es inválida. Abortando aplicación."
        log_error "Contenido erróneo:"
        cat "$TEMP_CONF"
        rm -f "$TEMP_CONF"
        exit 1
    fi
fi

log_success "Sistema de logs optimizado y protegido."