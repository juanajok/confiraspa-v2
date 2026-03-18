#!/usr/bin/env bash
# scripts/40-maintenance/restore_apps.sh
# Restauración selectiva de configuraciones desde backups, con tolerancia a fallos.
#
# Lee restore.json para saber qué restaurar, de dónde y con qué permisos.
# Soporta dos modos: ZIP (backups de los *Arr) y ficheros sueltos (Plex, rclone).
#
# NOTA SOBRE PERMISOS: Los ficheros .db (SQLite) no deben tener el bit de
# ejecución. restore.json original tenía "775" para .db — este script lo
# sanitiza automáticamente a 664 para ficheros no ejecutables.

set -euo pipefail
IFS=$'\n\t'

# ===========================================================================
# CABECERA UNIVERSAL
# ===========================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    export REPO_ROOT
fi

source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly CONFIG_FILE="${REPO_ROOT}/configs/static/restore.json"
readonly DEFAULT_USER="${ARR_USER:-media}"
readonly DEFAULT_GROUP="${ARR_GROUP:-media}"

# ===========================================================================
# FUNCIONES LOCALES
# ===========================================================================

# --- Error handler ---
on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."
}

# --- Parseo de argumentos ---
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

# --- Validar comandos del SO base ---
require_system_commands() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Comando requerido del sistema no disponible: ${cmd}"
            exit 1
        fi
    done
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Determinar usuario, grupo y servicio para una app ---
# Escribe en las variables: APP_SERVICE, APP_USER, APP_GROUP
resolve_app_identity() {
    local app_key="$1"
    local json_user="$2"
    local json_group="$3"
    local app_lower="${app_key,,}"

    APP_SERVICE=""
    APP_USER=""
    APP_GROUP=""

    case "${app_lower}" in
        plex)
            APP_SERVICE="plexmediaserver"
            APP_USER="${json_user:-plex}"
            APP_GROUP="${json_group:-${DEFAULT_GROUP}}"
            ;;
        rclone)
            # Rclone no es un servicio — es configuración de usuario.
            APP_SERVICE=""
            APP_USER="${json_user:-${SYS_USER:-pi}}"
            APP_GROUP="${json_group:-${SYS_USER:-pi}}"
            ;;
        *)
            # Por defecto: Suite *Arr
            APP_SERVICE="${app_lower}"
            APP_USER="${json_user:-${DEFAULT_USER}}"
            APP_GROUP="${json_group:-${DEFAULT_GROUP}}"
            ;;
    esac
}

# --- Encontrar el backup más reciente en un directorio ---
# Usa find + sort en lugar de ls -t (robusto con nombres especiales).
find_latest_backup() {
    local backup_dir="$1"
    local backup_ext="$2"

    find "${backup_dir}" -maxdepth 1 -type f -name "*${backup_ext}" -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn \
        | head -1 \
        | cut -f2
}

# --- Sanitizar permisos: quitar bit de ejecución a ficheros no-script ---
sanitize_permission() {
    local filename="$1"
    local perm="$2"

    # Scripts: mantener permisos tal cual
    case "${filename}" in
        *.sh|*.py|*.pl|*.rb) echo "${perm}"; return 0 ;;
    esac

    # Para todo lo demás: quitar bits de ejecución (AND con 666)
    local sanitized
    sanitized=$(printf '%o' $(( 8#${perm} & 8#666 )))

    if [[ "${sanitized}" != "${perm}" ]]; then
        log_warning "  Permiso sanitizado: ${filename} ${perm} → ${sanitized} (bit ejecutable inapropiado)"
    fi

    echo "${sanitized}"
}

# --- Restaurar ficheros desde un backup ZIP (*Arr) ---
restore_from_zip() {
    local app_key="$1"
    local backup_dir="$2"
    local backup_ext="$3"
    local restore_dir="$4"

    local latest_backup
    latest_backup=$(find_latest_backup "${backup_dir}" "${backup_ext}")

    if [[ -z "${latest_backup}" ]]; then
        log_warning "No hay backups ${backup_ext} en ${backup_dir}. Saltando."
        return 0
    fi

    log_info "Usando backup: $(basename "${latest_backup}")"

    local files_json
    files_json=$(jq -r ".\"${app_key}\".files_to_restore[]" "${CONFIG_FILE}")

    local file
    while IFS= read -r file; do
        [[ -z "${file}" ]] && continue

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "  [DRY-RUN] Restauraría: ${file}"
            continue
        fi

        # Limpiar archivos residuales de SQLite antes de restaurar.
        # Cuando SQLite corre, crea .db-wal y .db-shm junto a la BD.
        # Si restauramos un .db nuevo sin eliminarlos, SQLite intenta
        # hacer replay del WAL viejo sobre la BD nueva y corrompe o falla.
        if [[ "${file}" == *.db ]]; then
            rm -f "${restore_dir}/${file}" "${restore_dir}/${file}-wal" "${restore_dir}/${file}-shm" 2>/dev/null || true
            log_info "  Limpiados residuos SQLite: ${file}, ${file}-wal, ${file}-shm"
        fi

        if unzip -j -o "${latest_backup}" "${file}" -d "${restore_dir}" > /dev/null 2>&1; then
            log_info "  -> Restaurado: ${file}"
        else
            log_warning "  -> No se encontró '${file}' dentro del ZIP. Omitido."
        fi
    done <<< "${files_json}"
}

# --- Restaurar ficheros sueltos (Plex, rclone) ---
restore_loose_files() {
    local app_key="$1"
    local backup_dir="$2"
    local restore_dir="$3"

    local files_json
    files_json=$(jq -r ".\"${app_key}\".files_to_restore[]" "${CONFIG_FILE}")

    local file
    while IFS= read -r file; do
        [[ -z "${file}" ]] && continue

        local src="${backup_dir}/${file}"
        local dest="${restore_dir}/${file}"

        if [[ ! -f "${src}" ]]; then
            log_warning "  -> Archivo origen no encontrado: ${src}"
            continue
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "  [DRY-RUN] Copiaría: ${file}"
            continue
        fi

        execute_cmd "cp -a '${src}' '${dest}'" \
            "Copiando: ${file}"
    done <<< "${files_json}"
}

# --- Aplicar permisos específicos por fichero (desde el JSON) ---
apply_file_permissions() {
    local app_key="$1"
    local restore_dir="$2"
    local target_user="$3"
    local target_group="$4"

    log_info "Ajustando permisos de archivos..."

    local file perm full_path sanitized_perm
    while IFS=$'\t' read -r file perm; do
        [[ -z "${file}" ]] && continue

        full_path="${restore_dir}/${file}"
        sanitized_perm=$(sanitize_permission "${file}" "${perm}")

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "  [DRY-RUN] chmod ${sanitized_perm} / chown ${target_user}:${target_group} → ${file}"
            continue
        fi

        if [[ -f "${full_path}" ]]; then
            execute_cmd "chmod '${sanitized_perm}' '${full_path}'" \
                "Permisos ${sanitized_perm} → ${file}"
            execute_cmd "chown '${target_user}:${target_group}' '${full_path}'" \
                "Propietario ${target_user}:${target_group} → ${file}"
        else
            log_warning "  Fichero no encontrado para permisos: ${full_path}"
        fi
    done < <(jq -r ".\"${app_key}\".file_permissions | to_entries[] | \"\(.key)\t\(.value)\"" "${CONFIG_FILE}" 2>/dev/null)

    # Asegurar propiedad de todo el directorio y su contenido.
    # Los *Arr crean subcarpetas (MediaCover, logs, cache) que también
    # necesitan el propietario correcto para arrancar sin errores.
    if [[ "${DRY_RUN}" != "true" ]]; then
        execute_cmd "chown -R '${target_user}:${target_group}' '${restore_dir}'" \
            "Propietario recursivo: ${restore_dir}"
    fi
}

# --- Corregir BindAddress en config.xml tras restaurar desde backup ---
# Los backups de los *Arr pueden venir de otro entorno de red donde
# BindAddress estaba en 127.0.0.1 o localhost. En un NAS doméstico
# necesitamos que escuchen en todas las interfaces (*) para que otros
# dispositivos de la red puedan acceder a la web UI.
fix_bind_address() {
    local restore_dir="$1"
    local config_xml="${restore_dir}/config.xml"

    [[ -f "${config_xml}" ]] || return 0

    local current_bind
    current_bind=$(grep -oP '(?<=<BindAddress>)[^<]+' "${config_xml}" 2>/dev/null) || return 0

    # Solo corregir si está restringido a loopback
    case "${current_bind}" in
        127.0.0.1|localhost)
            if [[ "${DRY_RUN}" == "true" ]]; then
                log_info "  [DRY-RUN] Cambiaría BindAddress de '${current_bind}' a '*' en config.xml"
                return 0
            fi

            sed -i "s|<BindAddress>${current_bind}</BindAddress>|<BindAddress>*</BindAddress>|g" "${config_xml}"
            log_warning "  BindAddress corregido: ${current_bind} → * (acceso desde red local)"
            ;;
        \*|0.0.0.0)
            log_info "  BindAddress ya permite acceso de red (${current_bind})."
            ;;
        *)
            log_info "  BindAddress personalizado: ${current_bind}. No se modifica."
            ;;
    esac
}

# --- Procesar una app completa ---
process_app() {
    local app_key="$1"

    log_subsection "Procesando: ${app_key}"

    # FIX v5.1: Usar mapfile (una línea por campo) en lugar de @tsv + read.
    # Cuando backup_ext es "" (Plex, rclone), @tsv genera dos tabuladores
    # consecutivos que read colapsa en uno, desplazando todas las variables.
    # mapfile lee cada línea como un elemento del array — inmune a campos vacíos.
    local -a app_data
    mapfile -t app_data < <(jq -r ".\"${app_key}\" | .backup_dir, .backup_ext, .restore_dir, (.user // \"\"), (.group // \"\")" "${CONFIG_FILE}")

    local backup_dir="${app_data[0]:-}"
    local backup_ext="${app_data[1]:-}"
    local restore_dir="${app_data[2]:-}"
    local json_user="${app_data[3]:-}"
    local json_group="${app_data[4]:-}"

    # Validación defensiva: restore_dir nunca debe estar vacío
    if [[ -z "${restore_dir}" ]]; then
        log_error "restore_dir está vacío en el JSON para '${app_key}'. Verifica restore.json."
        return 1
    fi

    # Determinar identidad y servicio
    resolve_app_identity "${app_key}" "${json_user}" "${json_group}"
    log_info "Destino: ${restore_dir} (${APP_USER}:${APP_GROUP})"

    # A. Validar directorio de backup
    if [[ ! -d "${backup_dir}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "[DRY-RUN] Directorio de backup no existe: ${backup_dir} (normal en simulación)."
            return 0
        else
            log_warning "Directorio de backup no existe: ${backup_dir}. Saltando ${app_key}."
            return 0
        fi
    fi

    # B. Detener servicio si existe y está corriendo
    if [[ -n "${APP_SERVICE}" ]]; then
        if check_service_active "${APP_SERVICE}"; then
            execute_cmd "systemctl stop '${APP_SERVICE}'" \
                "Deteniendo ${APP_SERVICE} para restaurar"
        fi
    fi

    # C. Crear directorio destino si no existe
    if [[ ! -d "${restore_dir}" ]]; then
        execute_cmd "install -d -o '${APP_USER}' -g '${APP_GROUP}' -m 755 '${restore_dir}'" \
            "Creando directorio destino: ${restore_dir}"
    fi

    # D. Restaurar ficheros según el tipo de backup
    if [[ "${backup_ext}" == ".zip" ]]; then
        restore_from_zip "${app_key}" "${backup_dir}" "${backup_ext}" "${restore_dir}"
    else
        restore_loose_files "${app_key}" "${backup_dir}" "${restore_dir}"
    fi

    # E. Aplicar permisos específicos
    apply_file_permissions "${app_key}" "${restore_dir}" "${APP_USER}" "${APP_GROUP}"

    # F. Corregir BindAddress si el backup venía con loopback
    fix_bind_address "${restore_dir}"

    # G. Reiniciar servicio
    if [[ -n "${APP_SERVICE}" ]]; then
        execute_cmd "systemctl start '${APP_SERVICE}'" \
            "Iniciando ${APP_SERVICE}"
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Restauración de Configuraciones (Apps & Sistema)"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands jq unzip cp chmod chown systemctl

    ensure_package "jq"
    ensure_package "unzip"

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "Falta el archivo de configuración: ${CONFIG_FILE}"
        exit 1
    fi

    # --- 2. Iterar por cada app definida en el JSON ---
    local APP_SERVICE="" APP_USER="" APP_GROUP=""

    local app_keys
    app_keys=$(jq -r 'keys[]' "${CONFIG_FILE}")

    local app_key
    while IFS= read -r app_key; do
        [[ -z "${app_key}" ]] && continue
        process_app "${app_key}"
    done <<< "${app_keys}"

    log_success "Restauración completada."
}

main "$@"