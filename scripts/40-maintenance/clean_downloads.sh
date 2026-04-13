#!/usr/bin/env bash
# scripts/40-maintenance/clean_downloads.sh
# Limpieza idempotente de descargas ya importadas por los servicios *Arr.
#
# Compara los ficheros multimedia en SOURCE_DIR (descargas completas) contra
# las bibliotecas de destino (Series, Películas, Música, Libros). Si un fichero
# existe en ambos sitios (mismo inodo = hardlink, o mismo contenido = copia),
# se elimina de SOURCE_DIR para liberar espacio.
#
# Diseñado para ejecutarse desde cron (diariamente) con prioridad baja
# para no degradar los servicios multimedia en la RPi.

set -euo pipefail
IFS=$'\n\t'

# Cron ejecuta con PATH mínimo (/usr/bin:/bin). Asegurar rutas estándar
# para que stat, cmp, renice, ionice, flock, etc. se encuentren siempre.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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

# Cargar .env si no estamos bajo install.sh (ej: ejecución directa desde cron)
if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# Cuando cron ejecuta este script directamente, LOG_FILE está vacío y la
# salida de execute_cmd va a /dev/null. Inicializamos un log propio para
# que el detalle de los comandos ejecutados quede registrado.
if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="/var/log/clean_downloads.log"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly SOURCE_DIR="${DIR_TORRENTS:-/media/DiscoDuro/torrents/completos}"
readonly LOCK_FILE="/run/lock/confiraspa_cleaner.lock"
readonly MIN_AGE_MINUTES="+15"

# Extensiones multimedia que vale la pena comparar contra las bibliotecas.
# Todo lo demás (nfo, txt, jpg, srt...) se limpia como junk si el directorio
# queda vacío de ficheros multimedia tras la deduplicación.
readonly MEDIA_EXTENSIONS="mkv|mp4|avi|mp3|flac|epub|pdf|cbr|cbz|iso|m4v|m4a|ogg|opus|wav|aac"
readonly JUNK_EXTENSIONS="txt|nfo|url|website|srt|sub|idx|jpg|jpeg|png|exe|html|htm|sfv|md5|sha1"

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

# --- Adquirir lock exclusivo (evita ejecuciones simultáneas desde cron) ---
acquire_lock() {
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        log_error "El limpiador ya está en ejecución (lock: ${LOCK_FILE})."
        exit 1
    fi
}

# --- Reducir prioridad para no degradar servicios multimedia ---
# renice/ionice son operaciones de proceso, no de sistema de ficheros.
# Se ejecutan directamente (no vía execute_cmd) porque:
#   1. Deben aplicarse incluso en dry-run (el propio find consume I/O).
#   2. No mutan datos del usuario.
lower_priority() {
    # || true justificado: en contenedores o cgroups restringidos estos
    # comandos pueden fallar legítimamente sin consecuencias.
    renice -n 19 $$ > /dev/null 2>&1 || true  # Fallo aceptable en cgroups restringidos
    ionice -c3 -p $$ > /dev/null 2>&1 || true  # Fallo aceptable en kernels sin CFQ
}

# --- Validar variables del .env ---
validate_env_vars() {
    # DIR_TORRENTS se valida implícitamente al comprobar si SOURCE_DIR existe.
    # Las bibliotecas son opcionales — si no existen, build_target_dirs las descarta.
    # Solo validamos que las variables base del .env estén presentes.
    validate_var "DIR_TORRENTS" "${DIR_TORRENTS:-}"
}

# ===========================================================================
# FUNCIONES DE NEGOCIO
# ===========================================================================

# --- Construir lista de bibliotecas de destino ---
build_target_dirs() {
    local -n dirs_ref=$1

    local env_dirs=(
        "${DIR_SERIES:-}"
        "${DIR_MOVIES:-}"
        "${DIR_MUSIC:-}"
        "${DIR_BOOKS:-}"
    )

    local dir
    for dir in "${env_dirs[@]}"; do
        # || true: si la condición [[ ]] es falsa, el && devuelve 1.
        # Sin el || true, si el último dir del array no existe,
        # la función retorna 1 y set -e mata al caller.
        [[ -n "${dir}" && -d "${dir}" ]] && dirs_ref+=("${dir}") || true
    done

    return 0
}

# --- Comprobar si un fichero es multimedia por extensión ---
is_media_file() {
    local file="$1"
    local ext="${file##*.}"

    [[ "${ext,,}" =~ ^(${MEDIA_EXTENSIONS})$ ]]
}

# --- Buscar un duplicado de un fichero en las bibliotecas ---
# Compara primero por inodo (hardlink = instantáneo), luego por contenido.
# Retorna 0 si es duplicado, 1 si no.
find_duplicate() {
    local file_path="$1"
    local file_size="$2"
    local file_inode="$3"
    local file_dev="$4"
    shift 4
    local -a target_dirs=("$@")

    local lib_dir candidate candidate_inode candidate_dev
    for lib_dir in "${target_dirs[@]}"; do
        while IFS= read -r candidate; do
            candidate_inode=$(stat -c%i "${candidate}" 2>/dev/null) || continue
            candidate_dev=$(stat -c%d "${candidate}" 2>/dev/null) || continue

            # Mismo inodo EN EL MISMO DISPOSITIVO = hardlink (comparación instantánea).
            # El check de dispositivo es crítico: los inodos son únicos por filesystem,
            # no globalmente. En discos distintos pueden coincidir por azar en ficheros
            # completamente diferentes, causando un falso positivo y borrado incorrecto.
            if [[ "${file_dev}" == "${candidate_dev}" && "${file_inode}" == "${candidate_inode}" ]]; then
                return 0
            fi

            # Mismo tamaño + mismo contenido = copia real
            if cmp -s "${file_path}" "${candidate}"; then
                return 0
            fi
        done < <(find "${lib_dir}" -type f -size "${file_size}c" 2>/dev/null)
    done

    return 1
}

# --- Limpiar ficheros junk en un directorio si ya no quedan medios ---
# Imprime el número de ficheros junk eliminados a stdout para que el caller lo capture.
# IMPORTANTE: Todos los log_info van a >&2 para no contaminar el echo final
# que es lo único que debe llegar a stdout (capturado por $(...) en el caller).
cleanup_junk_in_dir() {
    local dir_path="$1"
    local count=0

    # Si aún quedan ficheros multimedia, no tocar el junk
    local media_remaining
    media_remaining=$(find "${dir_path}" -maxdepth 1 -type f -regextype posix-extended \
        -iregex ".*\.(${MEDIA_EXTENSIONS})" 2>/dev/null | wc -l)

    if [[ "${media_remaining}" -gt 0 ]]; then
        echo "0"
        return 0
    fi

    # No quedan medios — limpiar junk
    # RISK: Elimina ficheros basándose en extensión dentro de subdirectorios de
    # SOURCE_DIR. No afecta al directorio raíz SOURCE_DIR (guarded en el caller).
    # Mitigación: solo actúa en subdirectorios, solo extensiones de la allowlist.
    local junk_file
    while IFS= read -r junk_file; do
        execute_cmd "rm -f '${junk_file}'" "Junk eliminado: $(basename "${junk_file}")" >&2
        (( count++ )) || true  # (( )) retorna 1 cuando el resultado es 0 (false en aritmética)
    done < <(find "${dir_path}" -maxdepth 1 -type f -regextype posix-extended \
        -iregex ".*\.(${JUNK_EXTENSIONS})" 2>/dev/null)

    # Si el directorio quedó vacío, eliminarlo
    # RISK: rmdir solo funciona si el directorio está realmente vacío — seguro.
    if [[ -d "${dir_path}" ]] && [[ -z "$(ls -A "${dir_path}" 2>/dev/null)" ]]; then
        execute_cmd "rmdir '${dir_path}'" "Directorio vacío eliminado: ${dir_path}" >&2
    fi

    echo "${count}"
}

# --- Bucle principal de deduplicación ---
run_deduplication() {
    local -a target_dirs=("$@")
    local total_deleted=0
    local bytes_saved=0
    local junk_deleted=0

    log_info "Analizando duplicados en bibliotecas..."
    log_info "Origen:   ${SOURCE_DIR}"
    log_info "Destinos: ${target_dirs[*]}"

    local file_path file_basename file_size file_inode file_dev dir_path junk_count
    while IFS= read -r file_path; do
        file_basename="$(basename "${file_path}")"

        # Solo procesar ficheros multimedia
        if ! is_media_file "${file_path}"; then
            continue
        fi

        # Ignorar samples
        if [[ "${file_basename,,}" =~ sample ]]; then
            continue
        fi

        # Obtener metadatos
        file_size=$(stat -c%s "${file_path}" 2>/dev/null) || continue
        file_inode=$(stat -c%i "${file_path}" 2>/dev/null) || continue
        file_dev=$(stat -c%d "${file_path}" 2>/dev/null) || continue

        # Buscar duplicado en bibliotecas
        if find_duplicate "${file_path}" "${file_size}" "${file_inode}" "${file_dev}" "${target_dirs[@]}"; then
            if [[ "${DRY_RUN}" == "true" ]]; then
                log_warning "[DRY-RUN] Borraría: ${file_basename} ($(( file_size / 1024 / 1024 )) MB)"
            else
                # RISK: Elimina ficheros multimedia del directorio de descargas.
                # Mitigación: solo se borran ficheros que existen como duplicados
                # verificados (mismo inodo o mismo contenido byte a byte) en las
                # bibliotecas destino. El fichero original en la biblioteca no se toca.
                if execute_cmd "rm -f '${file_path}'" "Eliminado: ${file_basename}"; then
                    (( total_deleted++ )) || true  # (( )) retorna 1 cuando resultado es 0
                    (( bytes_saved += file_size )) || true  # Idem

                    # Limpiar junk en el mismo directorio si ya no quedan medios
                    dir_path="$(dirname "${file_path}")"
                    if [[ "${dir_path}" != "${SOURCE_DIR}" ]]; then
                        junk_count=$(cleanup_junk_in_dir "${dir_path}")
                        (( junk_deleted += junk_count )) || true  # Idem
                    fi
                fi
            fi
        fi
    done < <(find "${SOURCE_DIR}" -type f -mmin "${MIN_AGE_MINUTES}" 2>/dev/null)

    # --- Informe final ---
    if [[ "${DRY_RUN}" != "true" ]]; then
        local saved_display
        if [[ "${bytes_saved}" -ge 1048576 ]]; then
            saved_display="$(( bytes_saved / 1024 / 1024 )) MB"
        elif [[ "${bytes_saved}" -gt 0 ]]; then
            saved_display="$(( bytes_saved / 1024 )) KB"
        else
            saved_display="0 bytes"
        fi

        log_success "Limpieza completada."
        log_info "  Multimedia eliminados: ${total_deleted}"
        log_info "  Junk eliminado:        ${junk_deleted}"
        log_info "  Espacio recuperado:    ${saved_display}"
    else
        log_success "[DRY-RUN] Simulación de limpieza completada."
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    # --- Inicialización ---
    parse_args "$@"
    log_section "Limpieza de Descargas Redundantes"

    # --- 1. Validaciones ---
    validate_root
    require_system_commands find stat cmp rm renice ionice
    validate_env_vars

    # --- 2. Lock exclusivo y prioridad baja ---
    acquire_lock
    lower_priority

    # --- 3. Validar que el directorio origen existe ---
    if [[ ! -d "${SOURCE_DIR}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_warning "[DRY-RUN] Directorio origen no existe: ${SOURCE_DIR} (normal en simulación)."
            log_success "Limpieza completada (simulada)."
            return 0
        else
            log_error "Directorio origen no existe: ${SOURCE_DIR}"
            exit 1
        fi
    fi

    # --- 4. Construir lista de bibliotecas destino ---
    local target_dirs=()
    build_target_dirs target_dirs

    if [[ ${#target_dirs[@]} -eq 0 ]]; then
        log_warning "No hay bibliotecas de destino configuradas o accesibles."
        log_warning "Verifica DIR_SERIES, DIR_MOVIES, DIR_MUSIC, DIR_BOOKS en el .env."
        return 0
    fi

    # --- 5. Ejecutar deduplicación ---
    run_deduplication "${target_dirs[@]}"
}

main "$@"