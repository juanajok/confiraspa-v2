# lib/validators.sh

validate_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script requiere permisos de root (sudo)."
        exit 1
    fi
}

validate_dependencies() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Falta dependencia: $cmd"
            missing=1
        fi
    done
    [[ $missing -eq 1 ]] && exit 1
}

validate_var() {
    local var_name="$1"
    local var_value="${!var_name:-}" # Indirection bash

    if [[ -z "$var_value" ]]; then
        log_error "Variable requerida vacía: $var_name"
        exit 1
    fi
}