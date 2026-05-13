#!/usr/bin/env bash
# scripts/30-services/minidlna.sh
# Servidor DLNA/UPnP (ReadyMedia/MiniDLNA) para Smart TVs.
# v2.0 - Post peer-review: systemd drop-in, permisos correctos, fotos opcionales,
#         log_level configurable, smoke tests y aviso multicast.
#
# Cambios respecto a v1:
#   - CRITICAL: systemd drop-in para correr como ${ARR_USER} (no como minidlna)
#   - Terminología corregida: "web status" en vez de "web admin"
#   - Eliminado root_container=B (UX mejor con default del servidor)
#   - Soporte opcional para DIR_PHOTOS (si está en .env se indexa, si no se omite)
#   - MINIDLNA_LOG_LEVEL configurable vía .env (default: warn)
#   - Aviso multicast en post_checks
#   - Smoke tests: ss + curl al status

set -euo pipefail
IFS=$'\n\t'

# ===========================================================================
# CABECERA UNIVERSAL
# ===========================================================================
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    export REPO_ROOT
fi

source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly TARGET_CONF="/etc/minidlna.conf"
readonly SYSTEMD_DROPIN_DIR="/etc/systemd/system/minidlna.service.d"
readonly SYSTEMD_DROPIN="${SYSTEMD_DROPIN_DIR}/confiraspa-user.conf"
readonly DB_DIR="/var/cache/minidlna"
readonly LOG_DIR="/var/log/minidlna"

readonly DLNA_USER="${ARR_USER:-media}"
readonly DLNA_GROUP="${ARR_GROUP:-media}"
readonly DLNA_PORT="${MINIDLNA_PORT:-8200}"
readonly DLNA_FRIENDLY_NAME="${MINIDLNA_NAME:-Confiraspa NAS}"

# SECURITY: log_level configurable vía .env — default warn para no volcar datos sensibles
readonly DLNA_LOG_LEVEL="${MINIDLNA_LOG_LEVEL:-warn}"

# Rutas de biblioteca del .env. Si no están definidas, el script falla en
# validate_env_vars antes de llegar aquí. No usamos defaults que inventan
# rutas (riesgo de indexar carpetas equivocadas).
readonly DIR_VIDEO_SERIES="${DIR_SERIES:-}"
readonly DIR_VIDEO_MOVIES="${DIR_MOVIES:-}"
readonly DIR_AUDIO="${DIR_MUSIC:-}"
# DIR_PHOTOS es completamente opcional — si no está en .env no se indexan fotos
readonly DIR_PHOTOS="${DIR_PHOTOS:-}"

# ===========================================================================
# FUNCIONES LOCALES
# ===========================================================================

on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."
}

parse_args() {
    DRY_RUN="${DRY_RUN:-false}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN="true" ;;
            *) log_warning "Argumento desconocido: $1" ;;
        esac
        shift
    done
    export DRY_RUN
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

validate_env_vars() {
    validate_var "ARR_USER"  "${ARR_USER:-}"
    validate_var "ARR_GROUP" "${ARR_GROUP:-}"
    validate_var "PATH_LIBRARY" "${PATH_LIBRARY:-}"
    validate_var "DIR_SERIES" "${DIR_SERIES:-}"
    validate_var "DIR_MOVIES" "${DIR_MOVIES:-}"
    validate_var "DIR_MUSIC"  "${DIR_MUSIC:-}"
    # DIR_PHOTOS NO se valida — es opcional
}

# --- Renderizar minidlna.conf ---
render_minidlna_config() {
    local output_file="$1"

    # Construir líneas media_dir dinámicamente
    local media_dirs=""
    media_dirs+="media_dir=V,${DIR_VIDEO_SERIES}"$'\n'
    media_dirs+="media_dir=V,${DIR_VIDEO_MOVIES}"$'\n'
    media_dirs+="media_dir=A,${DIR_AUDIO}"$'\n'
    # Solo añadir fotos si DIR_PHOTOS está definido y no vacío
    if [[ -n "${DIR_PHOTOS}" ]]; then
        media_dirs+="media_dir=P,${DIR_PHOTOS}"$'\n'
        log_info "Biblioteca de fotos incluida: ${DIR_PHOTOS}"
    fi

    cat > "${output_file}" << EOF
# minidlna.conf — gestionado por Confiraspa. No editar manualmente.
# Regenerado por: ${SCRIPT_NAME}

friendly_name=${DLNA_FRIENDLY_NAME}
model_name=Confiraspa Media Server
model_number=2

user=${DLNA_USER}
port=${DLNA_PORT}

${media_dirs}
db_dir=${DB_DIR}
log_dir=${LOG_DIR}

# SECURITY: log_level configurable vía MINIDLNA_LOG_LEVEL en .env (default: warn)
# Para diagnóstico usa INFO, para producción usa warn.
log_level=general,artwork,database,inotify,scanner,metadata,http,ssdp,tivo=${DLNA_LOG_LEVEL}

# inotify: re-escaneo automático al detectar cambios sin esperar al cron
inotify=yes

# notify_interval: anuncia presencia cada ~15min vía SSDP
notify_interval=895

# presentation_url: %s se expande en runtime a la IP del servidor (no hardcodear IP)
presentation_url=http://%s:${DLNA_PORT}/

# Compatibilidad con clientes Samsung/Sony/LG
enable_tivo=no
strict_dlna=no

serial=12345678
EOF
    # NOTA: root_container eliminado intencionalmente — el default del servidor
    # ofrece mejor UX de navegación en TVs Samsung que root_container=B
}

# --- Configurar directorios de caché y logs ---
configure_directories() {
    if [[ ! -d "${DB_DIR}" ]]; then
        execute_cmd "install -d -o ${DLNA_USER} -g ${DLNA_GROUP} -m 755 '${DB_DIR}'" \
            "Creando directorio de caché DLNA"
    else
        execute_cmd "chown ${DLNA_USER}:${DLNA_GROUP} '${DB_DIR}'" \
            "Propietario de caché DLNA"
    fi

    if [[ ! -d "${LOG_DIR}" ]]; then
        execute_cmd "install -d -o ${DLNA_USER} -g ${DLNA_GROUP} -m 755 '${LOG_DIR}'" \
            "Creando directorio de logs DLNA"
    else
        execute_cmd "chown ${DLNA_USER}:${DLNA_GROUP} '${LOG_DIR}'" \
            "Propietario de logs DLNA"
    fi
}

# --- Verificar rutas de biblioteca ---
check_media_paths() {
    local missing=0
    local dir
    for dir in "${DIR_VIDEO_SERIES}" "${DIR_VIDEO_MOVIES}" "${DIR_AUDIO}"; do
        if [[ ! -d "${dir}" ]]; then
            log_warning "Ruta de biblioteca no encontrada: ${dir}"
            ((missing++)) || true
        fi
    done
    # Fotos son opcionales — no contar como fallo
    if [[ -n "${DIR_PHOTOS}" && ! -d "${DIR_PHOTOS}" ]]; then
        log_warning "DIR_PHOTOS definido pero no existe: ${DIR_PHOTOS}"
    fi

    if [[ ${missing} -gt 0 ]]; then
        log_warning "${missing} ruta(s) de biblioteca no existen. MiniDLNA arrancará y las indexará cuando aparezcan."
    fi
}

# --- Subir límite inotify para bibliotecas grandes ---
configure_inotify_limits() {
    local sysctl_file="/etc/sysctl.d/90-confiraspa-inotify.conf"
    local tempdir
    tempdir="$(mktemp -d)"
    local candidate="${tempdir}/sysctl.candidate"

    cat > "${candidate}" << EOF
# Gestionado por Confiraspa. El default 8192 es insuficiente en bibliotecas
# grandes con muchos subdirectorios. Subimos a 524288 (límite recomendado).
fs.inotify.max_user_watches = 524288
EOF

    if [[ -f "${sysctl_file}" ]] && cmp -s "${sysctl_file}" "${candidate}"; then
        log_info "Límites de inotify ya configurados."
        rm -rf "${tempdir}"
        return 0
    fi

    [[ -f "${sysctl_file}" ]] && create_backup "${sysctl_file}"
    execute_cmd "cp '${candidate}' '${sysctl_file}'" \
        "Instalando límites de inotify (524288 watches)"
    execute_cmd "sysctl -p '${sysctl_file}'" \
        "Aplicando límites de inotify"
    rm -rf "${tempdir}"
}

# --- CRITICAL: Systemd drop-in para correr como ${DLNA_USER} ---
# El unit de Debian tiene User=minidlna hardcodeado. Eso prevalece sobre
# la directiva user= en minidlna.conf y bloquea el acceso a /media/WDElements.
# RISK: El drop-in sobreescribe User= y Group= del unit original.
#       Si DLNA_USER no tiene permisos de lectura sobre las rutas de biblioteca,
#       el escaneo fallará silenciosamente. Mitigación: check_media_paths verifica
#       que los directorios existen antes de llegar aquí.
configure_systemd_dropin() {
    local candidate
    candidate="$(mktemp)"

    cat > "${candidate}" << EOF
# Drop-in de Confiraspa — gestionado automáticamente. No editar manualmente.
# Sobreescribe User/Group del unit de Debian para usar el usuario media (ARR_USER),
# que tiene permisos sobre /media/WDElements (mismo grupo que *Arr y Transmission).
# SECURITY: media es un usuario sin shell ni sudo — mínimo privilegio necesario.
[Service]
User=${DLNA_USER}
Group=${DLNA_GROUP}
EOF

    if [[ ! -d "${SYSTEMD_DROPIN_DIR}" ]]; then
        execute_cmd "mkdir -p '${SYSTEMD_DROPIN_DIR}'" \
            "Creando directorio drop-in systemd para minidlna"
    fi

    if [[ -f "${SYSTEMD_DROPIN}" ]] && cmp -s "${SYSTEMD_DROPIN}" "${candidate}"; then
        log_info "Drop-in systemd sin cambios."
        rm -f "${candidate}"
        return 1  # Sin cambios — no hace falta daemon-reload
    fi

    [[ -f "${SYSTEMD_DROPIN}" ]] && create_backup "${SYSTEMD_DROPIN}"
    execute_cmd "cp '${candidate}' '${SYSTEMD_DROPIN}'" \
        "Instalando drop-in systemd: User=${DLNA_USER}"
    execute_cmd "chmod 644 '${SYSTEMD_DROPIN}'" \
        "Permisos drop-in systemd"
    execute_cmd "systemctl daemon-reload" \
        "Recargando configuración de systemd"
    rm -f "${candidate}"
    return 0  # Cambios aplicados — requiere restart
}

# --- Desplegar minidlna.conf ---
deploy_minidlna_config() {
    local candidate="$1"

    if [[ -f "${TARGET_CONF}" ]] && cmp -s "${TARGET_CONF}" "${candidate}"; then
        log_info "Configuración de MiniDLNA sin cambios."
        return 1  # Sin cambios
    fi

    [[ -f "${TARGET_CONF}" ]] && create_backup "${TARGET_CONF}"
    execute_cmd "cp '${candidate}' '${TARGET_CONF}'" \
        "Instalando minidlna.conf"
    execute_cmd "chmod 644 '${TARGET_CONF}'" \
        "Permisos 644"
    execute_cmd "chown root:root '${TARGET_CONF}'" \
        "Propietario root:root"
    return 0  # Cambios aplicados
}

# --- Re-escaneo completo (borrar caché + restart) ---
trigger_full_rescan() {
    log_info "Forzando re-escaneo completo de la biblioteca..."

    if check_service_active minidlna; then
        execute_cmd "systemctl stop minidlna" \
            "Deteniendo MiniDLNA para re-escaneo"
    fi

    if [[ -f "${DB_DIR}/files.db" ]]; then
        execute_cmd "rm -f '${DB_DIR}/files.db'" \
            "Eliminando caché de base de datos"
    fi

    execute_cmd "systemctl start minidlna" \
        "Iniciando MiniDLNA con re-escaneo completo"
}

# --- Verificación final con smoke tests ---
post_checks() {
    if ! check_service_active minidlna; then
        log_error "MiniDLNA no está activo."
        log_error "Diagnóstico: journalctl -u minidlna -n 30"
        exit 1
    fi

    local ip
    ip="$(get_ip_address)"

    # Smoke test 1: puerto 8200/TCP escuchando
    log_info "Smoke test: verificando puerto ${DLNA_PORT}/TCP..."
    if ss -lntup 2>/dev/null | grep -q ":${DLNA_PORT}"; then
        log_success "Puerto ${DLNA_PORT}/TCP activo."
    else
        log_warning "Puerto ${DLNA_PORT}/TCP no aparece en ss. El servicio puede estar aún arrancando."
    fi

    # Smoke test 2: página de status accesible
    log_info "Smoke test: verificando status web..."
    if curl -sf --max-time 5 "http://127.0.0.1:${DLNA_PORT}/" > /dev/null 2>&1; then
        log_success "Status web MiniDLNA accesible en http://${ip}:${DLNA_PORT}/"
    else
        log_warning "Status web no respondió (puede tardar unos segundos en el primer arranque)."
    fi

    log_success "MiniDLNA operativo."
    log_info "  Nombre en red:  ${DLNA_FRIENDLY_NAME}"
    log_info "  Status web:     http://${ip}:${DLNA_PORT}/"
    log_info "  Bibliotecas indexadas:"
    log_info "    Vídeo: ${DIR_VIDEO_SERIES}"
    log_info "    Vídeo: ${DIR_VIDEO_MOVIES}"
    log_info "    Audio: ${DIR_AUDIO}"
    [[ -n "${DIR_PHOTOS}" ]] && log_info "    Fotos: ${DIR_PHOTOS}"
    log_info ""
    log_info "En la Samsung Q80C:"
    log_info "  1. Pulsa el botón Source → Home → Connected Devices"
    log_info "  2. Espera 30-60 segundos (descubrimiento SSDP)"
    log_info "  3. Aparecerá '${DLNA_FRIENDLY_NAME}' como dispositivo"
    log_info ""
    log_warning "AVISO MULTICAST: Si la RPi está en una red Wi-Fi separada del TV,"
    log_warning "o si el router tiene aislamiento de clientes activo, el TV no verá"
    log_warning "el servidor aunque los puertos 8200/TCP y 1900/UDP estén abiertos."
    log_warning "En ese caso verifica la configuración de multicast/SSDP en el router."
    log_info ""
    log_info "Primera indexación: puede tardar 5-15 min en bibliotecas grandes."
    log_info "Progreso: journalctl -u minidlna -f"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    local tempdir=""
    trap 'rm -rf "${tempdir:-}"' EXIT
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Configuración de Servidor DLNA — MiniDLNA v2.0"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands systemctl mktemp cp cmp sysctl install ss curl
    validate_env_vars

    if ! id "${DLNA_USER}" &>/dev/null; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "[DRY-RUN] Usuario '${DLNA_USER}' no existe (normal en simulación)."
        else
            log_error "Usuario '${DLNA_USER}' no existe. Ejecuta 00-users.sh primero."
            exit 1
        fi
    fi

    # --- 2. Paquete ---
    ensure_package minidlna

    # --- 3. Aviso de rutas faltantes (no bloquea) ---
    check_media_paths

    # --- 4. Directorios de caché y logs ---
    configure_directories

    # --- 5. Límites inotify para bibliotecas grandes ---
    configure_inotify_limits

    # --- 6. Generar y desplegar configuración ---
    tempdir="$(mktemp -d)"
    local candidate="${tempdir}/minidlna.conf"
    render_minidlna_config "${candidate}"

    local config_changed=0
    if deploy_minidlna_config "${candidate}"; then
        config_changed=1
    fi

    # --- 7. CRITICAL: Drop-in systemd para correr como ${DLNA_USER} ---
    local dropin_changed=0
    if configure_systemd_dropin; then
        dropin_changed=1
    fi

    # --- 8. Habilitar servicio en arranque ---
    execute_cmd "systemctl enable minidlna" \
        "Habilitando MiniDLNA en arranque"

    # --- 9. Aplicar cambios — re-escaneo solo si cambió la config o el drop-in ---
    if [[ ${config_changed} -eq 1 || ${dropin_changed} -eq 1 ]]; then
        log_info "Cambios detectados — forzando re-escaneo completo."
        trigger_full_rescan
    else
        if ! check_service_active minidlna; then
            execute_cmd "systemctl start minidlna" \
                "Iniciando MiniDLNA"
        fi
    fi

    # --- 10. Esperar a que el servicio responda en el puerto ---
    if ! wait_for_service "127.0.0.1" "${DLNA_PORT}" "MiniDLNA" 15; then
        log_warning "MiniDLNA no respondió en 15s — puede seguir indexando en background."
        log_warning "Verifica el estado con: journalctl -u minidlna -n 20"
    fi

    # --- 11. Verificación y smoke tests ---
    post_checks
}

main "$@"