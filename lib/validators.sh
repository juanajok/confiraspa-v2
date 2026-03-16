#!/bin/bash
# lib/validators.sh
# Validaciones defensivas para el framework Confiraspa

# Valida que el script se ejecute como root
validate_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script requiere permisos de root (sudo)."
        exit 1
    fi
}

# Valida comandos esenciales del sistema que DEBEN existir siempre
require_system_commands() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Herramienta de sistema no disponible: $cmd"
            exit 1
        fi
    done
}

# Valida comandos que provee un servicio (indulgente en Dry-Run)
require_service_commands() {
    # Si es Dry-Run, no validamos porque el paquete no se ha instalado realmente
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0

    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Binario del servicio no disponible tras instalación: $cmd"
            exit 1
        fi
    done
}

# Valida que una variable no esté vacía
validate_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    if [[ -z "$var_value" ]]; then
        log_error "Variable requerida vacía: $var_name"
        exit 1
    fi
}