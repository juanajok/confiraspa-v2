#!/bin/bash
# scripts/40-maintenance/logrotate.sh
# Descripción: Gestión integral de logs y rotación dinámica mediante JSON.
# Autor: Juan José Hipólito (Refactorizado v5 - Senior DevOps Standard)

set -euo pipefail

# --- CABECERA UNIVERSAL ---
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
source "$REPO_ROOT/lib/utils.sh"
source "$REPO_ROOT/lib/validators.sh"

# --- CONFIGURACIÓN ---
readonly JSON_CONFIG="$REPO_ROOT/configs/static/logrotate_jobs.json"
readonly TARGET_FILE="/etc/logrotate.d/confiraspa-dynamic"
readonly GLOBAL_CONF="/etc/logrotate.conf"
readonly JOURNAL_CONF="/etc/systemd/journald.conf"
readonly MAX_JOURNAL_SIZE="100M"

# --- FUNCIONES ---

optimize_system_logs() {
    log_info "Optimizando configuraciones de logs del sistema..."

    # 1. Habilitar compresión global de forma idempotente
    if grep -q "^#compress" "$GLOBAL_CONF"; then
        execute_cmd "Habilitando compresión global en logrotate" \
            "sed -i 's/^#compress/compress/' $GLOBAL_CONF"
    fi

    # 2. Limitar Journald (Vital para la vida útil de la SD)
    # Buscamos si SystemMaxUse ya está configurado al valor deseado
    if ! grep -q "^SystemMaxUse=$MAX_JOURNAL_SIZE" "$JOURNAL_CONF"; then
        log_info "Ajustando SystemMaxUse a $MAX_JOURNAL_SIZE en Journald..."
        
        # Si la línea existe pero con otro valor, la cambiamos; si no, la añadimos.
        if grep -q "^#\?SystemMaxUse=" "$JOURNAL_CONF"; then
            execute_cmd "Actualizando SystemMaxUse" \
                "sed -i 's/^[#]*SystemMaxUse=.*/SystemMaxUse=$MAX_JOURNAL_SIZE/' $JOURNAL_CONF"
        else
            execute_cmd "Añadiendo SystemMaxUse al final del archivo" \
                "bash -c 'echo \"SystemMaxUse=$MAX_JOURNAL_SIZE\" >> $JOURNAL_CONF'"
        fi
        execute_cmd "Reiniciando Journald" "systemctl restart systemd-journald"
    else
        log_info "Journald ya está limitado a $MAX_JOURNAL_SIZE. Saltando."
    fi
}

generate_dynamic_rules() {
    log_info "Iniciando generación de reglas desde JSON..."

    if [ ! -f "$JSON_CONFIG" ]; then
        log_warning "Archivo de configuración no encontrado: $JSON_CONFIG. Saltando."
        return 0
    fi

    if ! command -v jq &> /dev/null; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            log_warning "[DRY-RUN] 'jq' no instalado. Saltando generación en simulación."
            return 0
        else
            log_error "'jq' es necesario. Abortando."
            exit 1
        fi
    fi

    local temp_conf
    temp_conf=$(mktemp)
    
    {
        echo "# Configuración generada automáticamente por Confiraspa"
        echo "# Generado el: $(date)"
        echo ""
    } > "$temp_conf"

    while read -r job; do
        local name path rotate freq compress_flag missingok notifempty copytruncate create
        
        name=$(echo "$job" | jq -r '.name')
        path=$(echo "$job" | jq -r '.path')
        rotate=$(echo "$job" | jq -r '.rotate // 7')
        
        # Frecuencia
        if [[ "$(echo "$job" | jq -r '.daily')" == "true" ]]; then freq="daily"
        elif [[ "$(echo "$job" | jq -r '.weekly')" == "true" ]]; then freq="weekly"
        else freq=$(echo "$job" | jq -r '.frequency // "daily"'); fi

        # Booleanos a directivas
        compress_flag=$( [[ "$(echo "$job" | jq -r '.compress // true')" == "true" ]] && echo "compress" || echo "nocompress" )
        missingok=$( [[ "$(echo "$job" | jq -r '.missingok // true')" == "true" ]] && echo "missingok" || echo "nomissingok" )
        notifempty=$( [[ "$(echo "$job" | jq -r '.notifempty // true')" == "true" ]] && echo "notifempty" || echo "ifempty" )
        copytruncate=$( [[ "$(echo "$job" | jq -r '.copytruncate // false')" == "true" ]] && echo "copytruncate" || echo "" )
        create=$(echo "$job" | jq -r '.create // empty')

        log_info " -> Generando regla para: $name ($freq)"

{
            echo "$path {"
            echo "    su root adm"  # <--- FIX: Evita el error de 'insecure permissions'
            echo "    $freq"
            echo "    rotate $rotate"
            echo "    $compress_flag"
            [[ "$compress_flag" == "compress" ]] && echo "    delaycompress"
            echo "    $missingok"
            echo "    $notifempty"
            [[ -n "$copytruncate" ]] && echo "    $copytruncate"
            [[ -n "$create" ]] && echo "    create $create"
            echo "}"
            echo ""
        } >> "$temp_conf"

    done < <(jq -c '.jobs[]' "$JSON_CONFIG")

    # --- MEJORA EN LA VALIDACIÓN ---
    log_info "Validando sintaxis generada..."
    
    # Capturamos la salida de error para diagnosticar
    local val_output
    if val_output=$(logrotate -d "$temp_conf" 2>&1); then
        log_success "Sintaxis validada."
    else
        # Si el error es solo que el archivo de log no existe, lo ignoramos (es normal en instalaciones nuevas)
        if echo "$val_output" | grep -q "error: stat of"; then
            log_warning "Aviso: Algunos archivos de log aún no existen, pero la estructura es correcta."
        else
            log_error "Error de sintaxis real en logrotate:"
            echo "$val_output" >&2
            rm -f "$temp_conf"
            exit 1
        fi
    fi

    execute_cmd "Instalando reglas definitivas" "mv $temp_conf $TARGET_FILE"
    execute_cmd "Ajustando permisos" "chmod 644 $TARGET_FILE"
}

# --- MAIN ---

main() {
    log_section "Optimización de Logs (Logrotate + Journal)"
    validate_root

    optimize_system_logs
    generate_dynamic_rules

    log_success "Mantenimiento de logs finalizado con éxito."
}

main "$@"