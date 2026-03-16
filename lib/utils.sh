#!/bin/bash
# lib/utils.sh
# Descripción: Biblioteca central de funciones para el Framework Confiraspa
# Versión: 1.4.1 (C2 & C3 Hardened Fix)
# Autor: Juan José Hipólito

# --- 1. CONFIGURACIÓN DEL ENTORNO ---

export UTILS_VERSION="1.4.1"

# Detectar directorios base
if [ -z "${INSTALL_DIR:-}" ]; then
    export INSTALL_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"
fi
export CONFIG_DIR="${INSTALL_DIR}/configs"
export LOG_DIR="${INSTALL_DIR}/logs"

# --- C3 FIX: Inicialización segura de variables de estado ---
# Esto evita el error 'unbound variable' cuando set -u está activo
APT_UPDATED="${APT_UPDATED:-false}"

# Definición de colores ANSI (Solo si es TTY interactiva)
if [ -t 2 ]; then
    source "${INSTALL_DIR}/lib/colors.sh" 2>/dev/null || {
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
        BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'
    }
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; NC=''
fi

LOG_FILE="${LOG_FILE:-}"

# --- 2. SISTEMA DE LOGGING ---

_log_print() {
    local level="$1"
    local color="$2"
    local message="$3"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # CORRECCIÓN C3/BASH: Uso seguro de BASH_SOURCE para evitar error 'unbound variable'
    # Usamos ${BASH_SOURCE[2]-} en lugar de [2] directo
    local caller="${BASH_SOURCE[2]-}"
    local script_name="system"
    if [[ -n "$caller" ]]; then
        script_name=$(basename "$caller")
    fi

    # Salida por pantalla (stderr)
    echo -e "${color}[${timestamp}] [${level}]${NC} [${script_name}] ${message}" >&2

    # Salida a archivo (si existe y es escribible)
    if [[ -n "${LOG_FILE-}" ]]; then
        # Eliminamos códigos ANSI para el log de texto plano
        echo "[${timestamp}] [${level}] [${script_name}] ${message}" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    fi
}

log_header() { 
    echo -e "\n${BLUE}=====================================================${NC}" >&2
    echo -e "${BLUE}   $1 ${NC}" >&2
    echo -e "${BLUE}=====================================================${NC}" >&2
    # CORRECCIÓN: Usamos el fallback /dev/null si la variable está vacía
    echo -e "\n=== $1 ===" >> "${LOG_FILE:-/dev/null}"
}

log_section()    { echo -e "\n${MAGENTA}--- $1 ---${NC}" >&2; echo "--- $1 ---" >> "${LOG_FILE:-/dev/null}"; }
log_subsection() { echo -e "\n${CYAN} -> $1${NC}" >&2; echo " -> $1" >> "${LOG_FILE:-/dev/null}"; }

log_info()    { _log_print "INFO" "${BLUE}" "$1"; }
log_success() { _log_print "OK"   "${GREEN}" "$1"; }
log_warning() { _log_print "WARN" "${YELLOW}" "$1"; }
log_error()   { _log_print "ERROR" "${RED}" "$1"; }

init_logging() {
    mkdir -p "$(dirname "$1")"
    touch "$1"
}

# --- 3. GESTIÓN DE ERRORES E INICIALIZACIÓN ---

setup_error_handling() {
    set -o pipefail
    trap 'log_error "Error inesperado en línea $LINENO (Exit Code: $?)"' ERR
}

setup_paths() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    if [[ -z "$LOG_FILE" ]]; then
        local script_name=$(basename "$0" .sh)
        LOG_FILE="${LOG_DIR}/${script_name}.log"
        touch "$LOG_FILE"
        chmod 640 "$LOG_FILE"
    fi
}

# --- 4. VALIDACIONES DE SISTEMA ---

check_network_connectivity() {
    local target="${1:-8.8.8.8}"
    if ! ping -c 1 -W 1 "$target" &>/dev/null; then
        log_warning "Sin conectividad con $target. Operaciones de red pueden fallar."
        return 1
    fi
    return 0
}

check_disk_space() {
    local path="$1"
    local min_mb="${2:-1024}"
    [ ! -d "$path" ] && path=$(dirname "$path")
    local available=$(df -Pm "$path" | awk 'END {print $4}')
    if [ "$available" -lt "$min_mb" ]; then
        log_error "Espacio insuficiente en $path. Libres: ${available}MB (Mínimo: ${min_mb}MB)"
        return 1
    fi
    return 0
}

get_system_arch() {
    local arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64) echo "x64" ;;
        arm64) echo "arm64" ;;
        armhf) echo "arm" ;;
        *)     echo "unknown" ;;
    esac
}

get_ip_address() {
    ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1"
}

# --- 5. GESTIÓN DE PAQUETES ---

is_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

ensure_package() {
    local pkg="$1"
    if ! is_package_installed "$pkg"; then
        # Uso seguro de APT_UPDATED gracias a la inicialización al principio del archivo
        if [ "$APT_UPDATED" = false ]; then
            log_info "Actualizando índices de APT (Lazy Update)..."
            execute_cmd "apt-get update -qq"
            APT_UPDATED=true
        fi
        log_info "Instalando dependencia: $pkg..."
        execute_cmd "apt-get install -y -qq $pkg" "Instalación de $pkg"
    fi
}

# --- 6. EJECUCIÓN SEGURA Y BACKUPS ---

# C2 FIX: Sustitución de 'eval' por 'bash -c' para mayor aislamiento y seguridad
execute_cmd() {
    local cmd="${1-}"
    local msg_arg="${2-}"

    local msg
    if [[ -n "$msg_arg" ]]; then
        msg="$msg_arg"
    else
        msg="Ejecutando: $cmd"
    fi
    log_info "$msg"

    if [[ "${DRY_RUN:-false}" = true ]]; then
        echo -e "${YELLOW}  [DRY-RUN]${NC} $cmd" >&2
        # Drena stdin si viene de un pipe (ej: envsubst | execute_cmd "tee ...").
        # Sin esto, el proceso upstream muere con SIGPIPE y pipefail aborta el script.
        # En producción este path no se ejecuta, así que no hay riesgo de perder datos.
        [[ -p /dev/stdin ]] && cat > /dev/null
        return 0
    fi

    if bash -c "$cmd" >> "${LOG_FILE:-/dev/null}" 2>&1; then
        return 0
    else
        local exit_code=$?
        log_error "Fallo (Exit $exit_code): $cmd"
        return $exit_code
    fi
}

# run_check: Para comandos de VALIDACIÓN (testparm, jq, nginx -t...)
# En Dry-run omite la prueba (porque el archivo no existe).
run_check() {
    local cmd="${1-}"
    local msg="${2:-Verificando: $cmd}"
    log_info "$msg"

    if [[ "${DRY_RUN:-false}" = true ]]; then
        log_warning "[DRY-RUN] Validación omitida (archivo no escrito): $cmd"
        return 0
    fi

    if bash -c "$cmd" >> "${LOG_FILE:-/dev/null}" 2>&1; then
        return 0
    else
        local exit_code=$?
        log_error "Validación fallida (Exit $exit_code): $cmd"
        return $exit_code
    fi
}

create_backup() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        log_info "Backup: $(basename "$file") -> $(basename "$backup")"
        cp -a "$file" "$backup"
    fi
}
# --- 7. DESCARGAS ROBUSTAS (RETRY LOGIC) ---

download_secure() {
    local url="$1"
    local output="$2"
    local expected_sha256="${3:-}"
    local retries=3
    local wait_time=5

    log_info "Descargando: $url"

    for ((i=1; i<=retries; i++)); do
        if curl --connect-timeout 10 --max-time 300 --retry 3 -fsSL -o "$output" "$url"; then
            
            if [[ -n "$expected_sha256" ]]; then
                local actual_sha256
                actual_sha256=$(sha256sum "$output" | awk '{print $1}')
                
                if [[ "$actual_sha256" != "$expected_sha256" ]]; then
                    log_error "Hash inválido (Intento $i). Esperado: $expected_sha256 - Obtenido: $actual_sha256"
                    rm -f "$output"
                    if [[ $i -eq $retries ]]; then return 1; fi
                    sleep "$wait_time"
                    continue
                else
                    log_info "Hash verificado."
                    return 0
                fi
            fi
            
            return 0
        else
            log_warning "Fallo descarga ($i/$retries)."
            rm -f "$output"
            if [[ $i -lt $retries ]]; then
                sleep "$wait_time"
                wait_time=$((wait_time * 2)) # Backoff exponencial
            fi
        fi
    done

    log_error "Fallo crítico: Descarga fallida tras $retries intentos."
    return 1
}
# --- 8. HEALTH CHECKS ---

# Comprueba si un servicio systemd está activo.
# En dry-run: devuelve éxito simulado.
check_service_active() {
    local service="$1"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "[DRY-RUN] Health check omitido para servicio '$service'."
        return 0
    fi

    systemctl is-active --quiet "$service"
}

# Espera a que un puerto esté respondiendo (TCP)
wait_for_service() {
    local host="$1"
    local port="$2"
    local name="${3:-Service}"
    local timeout="${4:-30}"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "[DRY-RUN] Health check de puerto omitido para $name ($host:$port)."
        return 0
    fi

    log_info "Esperando a que $name escuche en $host:$port..."
    for ((i=0; i<timeout; i++)); do
        # Truco Bash para comprobar puerto sin netcat
        if timeout 1 bash -c "</dev/tcp/$host/$port" &>/dev/null; then
            log_success "$name está operativo ($host:$port)."
            return 0
        fi
        sleep 1
    done

    log_error "Timeout esperando a $name en $port tras $timeout segundos."
    return 1
}

# Wrapper para testparm, jq, etc.
run_check() {
    local cmd="${1-}"
    local msg="${2:-Verificando: $cmd}"
    log_info "$msg"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "[DRY-RUN] Validación omitida (archivo no escrito): $cmd"
        return 0
    fi

    if bash -c "$cmd" >> "${LOG_FILE:-/dev/null}" 2>&1; then
        return 0
    else
        local exit_code=$?
        log_error "Validación fallida (Exit $exit_code): $cmd"
        return $exit_code
    fi
}


log_debug() {
    [[ "${DEBUG:-false}" == "true" ]] && _log_print "DEBUG" "${CYAN}" "$1"
    return 0   # ← evita que set -e la mate si DEBUG=false
}