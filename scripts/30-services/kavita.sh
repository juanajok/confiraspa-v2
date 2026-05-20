#!/usr/bin/env bash
# scripts/30-services/kavita.sh
#
# Layout en disco (FHS-compliant):
#   /opt/kavita/releases/${version}/   binarios (solo lectura en runtime)
#   /opt/kavita/current                symlink al release activo → rollback atómico
#   /var/lib/kavita/                   datos persistentes (StateDirectory systemd)
#
# La redirección de datos se hace vía symlink por release:
#   /opt/kavita/releases/${ver}/config → /var/lib/kavita
# Kavita busca config/ relativo a WorkingDirectory y sigue el symlink.
# Esto garantiza que los datos sobreviven actualizaciones de versión.
#
# El puerto se configura vía ASPNETCORE_URLS en la unidad systemd.
# No se modifica appsettings.json (Kavita lo gestiona internamente).
#
# Las bibliotecas se añaden desde la Web UI tras la instalación.

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

if [[ -f "${REPO_ROOT}/.env" ]]; then
    source "${REPO_ROOT}/.env"
fi

# ===========================================================================
# CONSTANTES
# ===========================================================================
readonly SERVICE_NAME="kavita"
readonly KAVITA_BASE_DIR="/opt/kavita"
readonly KAVITA_RELEASES_DIR="${KAVITA_BASE_DIR}/releases"
readonly KAVITA_CURRENT="${KAVITA_BASE_DIR}/current"      # symlink
readonly KAVITA_DATA_DIR="/var/lib/kavita"                # StateDirectory
readonly KAVITA_SERVICE_FILE="/etc/systemd/system/kavita.service"
readonly KAVITA_LOCK_FILE="/var/lock/kavita-install.lock"
readonly KAVITA_API_URL="https://api.github.com/repos/Kareadita/Kavita/releases/latest"

# Puerto con default si no está en .env; validate_var no aplica porque tiene default
readonly KAVITA_PORT="${KAVITA_PORT:-5000}"

# Variables globales rellenas por get_latest_release()
KAVITA_LATEST_VERSION=""
KAVITA_DOWNLOAD_URL=""

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
# LOCKFILE — evita ejecuciones concurrentes
# El FD 200 se cierra (y el lock se libera) automáticamente al salir el proceso.
# ===========================================================================
acquire_lock() {
    exec 200>"${KAVITA_LOCK_FILE}"
    if ! flock -n 200; then
        log_error "Otra instalación de Kavita está en curso. Espera a que termine."
        exit 1
    fi
}

# ===========================================================================
# DETECCIÓN DE ARQUITECTURA
# Reutiliza get_system_arch() de utils.sh (basada en dpkg --print-architecture)
# ===========================================================================
detect_kavita_arch() {
    local sys_arch
    sys_arch="$(get_system_arch)"
    case "${sys_arch}" in
        arm64)   echo "linux-arm64" ;;
        arm)     echo "linux-arm"   ;;
        x64)     echo "linux-x64"   ;;
        *)
            log_error "Arquitectura no soportada por Kavita: ${sys_arch} (dpkg)"
            exit 1
            ;;
    esac
}

# ===========================================================================
# CONSULTAR ÚLTIMO RELEASE DE GITHUB
# Rellena KAVITA_LATEST_VERSION y KAVITA_DOWNLOAD_URL.
# ===========================================================================
get_latest_release() {
    local arch="$1"
    local api_response

    log_info "Consultando última versión de Kavita en GitHub..."

    # curl directo para metadatos JSON (download_secure es para ficheros binarios)
    api_response="$(curl --connect-timeout 10 --max-time 30 -fsSL \
        -H "Accept: application/vnd.github.v3+json" \
        "${KAVITA_API_URL}")" || {
        log_error "No se pudo consultar la API de GitHub. Verifica la conectividad."
        exit 1
    }

    KAVITA_LATEST_VERSION="$(printf '%s' "${api_response}" | jq -r '.tag_name')"
    KAVITA_DOWNLOAD_URL="$(printf '%s' "${api_response}" | \
        jq -r --arg arch "${arch}" \
        '.assets[] | select(.name | test("kavita-" + $arch + "\\.tar\\.gz$")) | .browser_download_url')"

    if [[ -z "${KAVITA_LATEST_VERSION}" || "${KAVITA_LATEST_VERSION}" == "null" ]]; then
        log_error "No se pudo obtener la versión más reciente de Kavita."
        exit 1
    fi

    if [[ -z "${KAVITA_DOWNLOAD_URL}" || "${KAVITA_DOWNLOAD_URL}" == "null" ]]; then
        log_error "No se encontró asset para arch='${arch}' en el release ${KAVITA_LATEST_VERSION}."
        log_error "Assets disponibles:"
        # Proceso de sustitución: evita subshell y respeta set -e
        while IFS= read -r name; do
            log_error "  ${name}"
        done < <(printf '%s' "${api_response}" | jq -r '.assets[].name')
        exit 1
    fi

    log_info "Última versión disponible: ${KAVITA_LATEST_VERSION} (${arch})"
}

# ===========================================================================
# INSTALACIÓN ATÓMICA
#
# Layout por release:
#   /opt/kavita/releases/${version}/Kavita       binario
#   /opt/kavita/releases/${version}/config  →  /var/lib/kavita  (symlink)
#   /opt/kavita/current  →  releases/${version}  (symlink activo)
#
# La actualización de versión es atómica: ln -sfn es una operación del kernel.
# ===========================================================================
install_kavita_release() {
    local release_dir="${KAVITA_RELEASES_DIR}/${KAVITA_LATEST_VERSION}"

    # Idempotencia: release ya descargado Y es el activo
    if [[ -f "${release_dir}/Kavita" ]]; then
        local current_target
        current_target="$(readlink "${KAVITA_CURRENT}" 2>/dev/null || true)"
        if [[ "${current_target}" == "${release_dir}" ]]; then
            log_info "Kavita ${KAVITA_LATEST_VERSION} ya está instalado y activo."
            return 0
        fi
        # Release descargado pero symlink no apunta aquí → activar sin re-descargar
        log_info "Activando release ${KAVITA_LATEST_VERSION} (ya descargado)..."
        activate_release "${release_dir}"
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Descargaría Kavita ${KAVITA_LATEST_VERSION} en ${release_dir}."
        log_info "[DRY-RUN] Actualizaría symlink ${KAVITA_CURRENT} → ${release_dir}."
        return 0
    fi

    # Parar servicio antes de actualizar si hay una versión activa
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        execute_cmd "systemctl stop '${SERVICE_NAME}'" "Deteniendo Kavita para actualizar"
    fi

    log_info "Descargando Kavita ${KAVITA_LATEST_VERSION}..."

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local tmp_tar="${tmp_dir}/kavita.tar.gz"

    # NOTA: GitHub Releases no publica checksums SHA256 como assets separados para Kavita.
    # La integridad del transporte queda garantizada por TLS (GitHub CA).
    if ! download_secure "${KAVITA_DOWNLOAD_URL}" "${tmp_tar}"; then
        log_error "Fallo al descargar Kavita ${KAVITA_LATEST_VERSION}."
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # Verificar espacio antes de descargar: ~150 MB binario + margen para release anterior
    check_disk_space "${KAVITA_BASE_DIR}" 400

    execute_cmd "mkdir -p '${release_dir}'" "Creando directorio de release"

    # Sondear estructura del tarball: si el primer entry es un directorio (termina en /)
    # aplicar --strip-components=1 para normalizar la raíz del release.
    # Kavita ha cambiado el layout de su tarball entre versiones; no asumir estructura fija.
    #
    # Proceso de sustitución en vez de pipe: "tar -tzf | head -1" con pipefail activo
    # provoca SIGPIPE (exit 141) porque head cierra el pipe al leer la primera línea.
    local strip_components=0
    local first_entry=""
    while IFS= read -r first_entry; do break; done < <(tar -tzf "${tmp_tar}" 2>/dev/null)
    if [[ "${first_entry}" == */ ]]; then
        strip_components=1
        log_info "Subdirectorio raíz '${first_entry%/}' detectado, normalizando con --strip-components=1"
    fi

    log_info "Extrayendo en ${release_dir}..."
    if ! tar -xzf "${tmp_tar}" -C "${release_dir}" --strip-components="${strip_components}"; then
        log_error "Fallo al extraer el archivo de Kavita."
        rm -rf "${tmp_dir}" "${release_dir}"
        exit 1
    fi
    rm -rf "${tmp_dir}"

    # Detectar el binario: no asumimos nombre exacto ni profundidad fija
    local kavita_bin
    kavita_bin="$(find "${release_dir}" -maxdepth 2 -type f -perm -111 \
        \( -iname "kavita" \) | head -n1)"

    if [[ -z "${kavita_bin}" ]]; then
        log_error "Ejecutable 'kavita' no encontrado en ${release_dir} (búsqueda maxdepth 2)."
        log_error "Estructura extraída del release:"
        while IFS= read -r entry; do
            log_error "  ${entry}"
        done < <(find "${release_dir}" -maxdepth 3 | sort)
        rm -rf "${release_dir}"
        exit 1
    fi

    log_info "Binario detectado: ${kavita_bin}"

    # Si el binario quedó anidado (strip insuficiente), mover todo el contenido a la raíz.
    # Esto ocurre si el tarball tiene >1 nivel de anidamiento no detectado por first_entry.
    # RISK: mv falla si hay colisión de nombres. El release_dir es nuevo y creado por
    # este script, por lo que no hay contenido previo → colisión imposible.
    local bin_dir
    bin_dir="$(dirname "${kavita_bin}")"
    if [[ "${bin_dir}" != "${release_dir}" ]]; then
        log_warning "Anidamiento adicional en '${bin_dir}', normalizando estructura..."
        execute_cmd "find '${bin_dir}' -mindepth 1 -maxdepth 1 -exec mv -t '${release_dir}/' {} +" \
            "Moviendo contenido a raíz de release"
        execute_cmd "rmdir '${bin_dir}'" "Eliminando subdirectorio vacío"
    fi

    # Symlink de datos: Kavita busca config/ relativo a WorkingDirectory
    # SECURITY: ruta absoluta → estable tras cambios de release
    ln -sfn "${KAVITA_DATA_DIR}" "${release_dir}/config"

    activate_release "${release_dir}"
    log_success "Kavita ${KAVITA_LATEST_VERSION} instalado."
}

# Conmuta el symlink /opt/kavita/current de forma atómica y purga releases viejos.
activate_release() {
    local release_dir="$1"

    # ln -sfn es atómico a nivel de syscall (rename(2) internamente)
    execute_cmd "ln -sfn '${release_dir}' '${KAVITA_CURRENT}'" \
        "Activando release $(basename "${release_dir}")"

    prune_old_releases
}

# Mantiene solo los últimos 2 releases (rollback inmediato con re-ejecución del script)
prune_old_releases() {
    [[ -d "${KAVITA_RELEASES_DIR}" ]] || return 0

    local keep=2
    local count=0
    local rel

    while IFS= read -r rel; do
        count=$((count + 1))
        [[ ${count} -gt ${keep} ]] || continue
        execute_cmd "rm -rf '${rel}'" "Eliminando release antiguo: $(basename "${rel}")"
    done < <(find "${KAVITA_RELEASES_DIR}" -maxdepth 1 -mindepth 1 -type d \
             -printf '%T@ %p\n' | sort -rn | awk '{print $2}')
}

# ===========================================================================
# USUARIO DE SISTEMA Y PERMISOS
# ===========================================================================
setup_user_and_permissions() {
    local media_group="${ARR_GROUP:-media}"

    # Usuario de servicio dedicado, sin shell ni home
    if ! id "${SERVICE_NAME}" &>/dev/null; then
        execute_cmd "useradd --system --no-create-home --shell /usr/sbin/nologin '${SERVICE_NAME}'" \
            "Creando usuario de sistema '${SERVICE_NAME}'"
    else
        log_info "Usuario '${SERVICE_NAME}' ya existe."
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Configuraría permisos y grupos para ${SERVICE_NAME}."
        return 0
    fi

    # Acceso a las bibliotecas de medios (sin chmod 777)
    if ! id -nG "${SERVICE_NAME}" 2>/dev/null | grep -qw "${media_group}"; then
        execute_cmd "usermod -aG '${media_group}' '${SERVICE_NAME}'" \
            "Añadiendo ${SERVICE_NAME} al grupo ${media_group}"
    else
        log_info "Usuario '${SERVICE_NAME}' ya pertenece al grupo '${media_group}'."
    fi

    # Directorio de datos (systemd StateDirectory lo gestiona en runtime,
    # pero lo creamos aquí para que el symlink config → /var/lib/kavita sea funcional
    # antes del primer arranque)
    execute_cmd "mkdir -p '${KAVITA_DATA_DIR}'" "Creando directorio de datos"
    execute_cmd "chown '${SERVICE_NAME}:${SERVICE_NAME}' '${KAVITA_DATA_DIR}'" \
        "Asignando propiedad de ${KAVITA_DATA_DIR}"
    execute_cmd "chmod 750 '${KAVITA_DATA_DIR}'" "Permisos de directorio de datos"

    # Propiedad de binarios — 755: el grupo video/render puede necesitar acceso indirecto
    # SECURITY: el aislamiento real lo provee el sandboxing systemd (ProtectSystem=strict)
    execute_cmd "chown -R '${SERVICE_NAME}:${SERVICE_NAME}' '${KAVITA_BASE_DIR}'" \
        "Asignando propiedad de ${KAVITA_BASE_DIR}"

    # Detectar el binario a través del symlink current (no asumir ruta fija)
    # -L sigue symlinks para que find resuelva /opt/kavita/current → release dir
    local kavita_bin
    kavita_bin="$(find -L "${KAVITA_CURRENT}" -maxdepth 1 -type f -perm -111 \
        \( -iname "kavita" \) 2>/dev/null | head -n1)"
    if [[ -n "${kavita_bin}" ]]; then
        execute_cmd "chmod 755 '${kavita_bin}'" "Permisos del binario Kavita"
    else
        log_warning "Binario kavita no encontrado bajo ${KAVITA_CURRENT} para chmod (dry-run o instalación pendiente)."
    fi
}

# ===========================================================================
# UNIDAD SYSTEMD
# Usa mktemp + install en vez de heredoc | tee: más predecible y auditabe.
# ===========================================================================
create_systemd_service() {
    if [[ -f "${KAVITA_SERVICE_FILE}" ]]; then
        log_info "Unidad systemd de Kavita ya existe."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Crearía unidad systemd en ${KAVITA_SERVICE_FILE}."
        return 0
    fi

    log_info "Creando unidad systemd para Kavita..."

    local tmp_unit
    tmp_unit="$(mktemp --suffix=.service)"

    # WorkingDirectory resuelve el symlink /opt/kavita/current → release activo.
    # Kavita busca config/ en el cwd → sigue symlink → /var/lib/kavita (StateDirectory).
    # ASPNETCORE_URLS evita modificar appsettings.json (más robusto ante cambios de schema).
    cat > "${tmp_unit}" <<EOF
[Unit]
Description=Kavita — servidor de cómics, manga y libros
After=network.target

[Service]
User=${SERVICE_NAME}
Group=${SERVICE_NAME}
WorkingDirectory=${KAVITA_CURRENT}
ExecStart=${KAVITA_CURRENT}/Kavita
Environment=ASPNETCORE_URLS=http://0.0.0.0:${KAVITA_PORT}
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
# KillMode=mixed: señal SIGTERM al proceso principal + SIGKILL al cgroup si no responde
# Evita procesos .NET huérfanos que KillMode=process puede dejar activos
KillMode=mixed

# --- Sandboxing systemd ---
# StateDirectory crea /var/lib/kavita/ y lo añade a ReadWritePaths automáticamente
StateDirectory=${SERVICE_NAME}
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
# read-only (no strict) para que Kavita pueda leer bibliotecas en /home si las hay
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
LockPersonality=true
SystemCallArchitectures=native
# MemoryDenyWriteExecute=true incompatible con .NET 8 JIT (requiere W+X en memoria)

[Install]
WantedBy=multi-user.target
EOF

    execute_cmd "install -o root -g root -m 644 '${tmp_unit}' '${KAVITA_SERVICE_FILE}'" \
        "Instalando unidad systemd de Kavita"
    rm -f "${tmp_unit}"

    log_success "Unidad systemd de Kavita creada."
}

# ===========================================================================
# ARRANQUE DEL SERVICIO
# ===========================================================================
enable_and_start_service() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Habilitaría e iniciaría el servicio ${SERVICE_NAME}."
        return 0
    fi

    execute_cmd "systemctl daemon-reload" "Recargando systemd"

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        log_info "Servicio ${SERVICE_NAME} activo. Reiniciando..."
        execute_cmd "systemctl restart '${SERVICE_NAME}'" "Reiniciando ${SERVICE_NAME}"
    else
        execute_cmd "systemctl enable --now '${SERVICE_NAME}'" \
            "Habilitando e iniciando ${SERVICE_NAME}"
    fi
}

# ===========================================================================
# VERIFICACIÓN POST-INSTALACIÓN
# ===========================================================================
post_checks() {
    if ! wait_for_service "localhost" "${KAVITA_PORT}" "Kavita" 30; then
        if [[ "${DRY_RUN}" != "true" ]]; then
            log_error "Kavita no responde en el puerto ${KAVITA_PORT} tras 30s."
            log_error "Diagnóstico: journalctl -u ${SERVICE_NAME} -n 50"
            exit 1
        fi
    fi

    if [[ "${DRY_RUN}" != "true" ]]; then
        local host_ip
        host_ip="$(get_ip_address)"
        local active_version
        active_version="$(basename "$(readlink "${KAVITA_CURRENT}")")"

        log_success "Kavita instalado y operativo."
        log_info "  Web UI:   http://${host_ip}:${KAVITA_PORT}"
        log_info "  Versión:  ${active_version}"
        log_info "  Datos:    ${KAVITA_DATA_DIR}"
        log_info "  Releases: ${KAVITA_RELEASES_DIR}/"
        log_info ""
        log_info "  PRIMER ARRANQUE: Kavita solicita crear el usuario administrador."
        if [[ -n "${DIR_BOOKS:-}" ]]; then
            log_info "  Añade tu biblioteca desde la Web UI:"
            log_info "    Libros → ${DIR_BOOKS}"
        fi
        log_info ""
        log_warning "Rollback a versión anterior:"
        log_warning "  sudo ln -sfn \$(ls -d ${KAVITA_RELEASES_DIR}/*/ | tail -2 | head -1) ${KAVITA_CURRENT}"
        log_warning "  sudo systemctl restart kavita"
    else
        log_success "Instalación de Kavita simulada correctamente."
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Instalación de Kavita (servidor de cómics, manga y libros)"

    # --- 1. Validaciones previas ---
    validate_root
    require_system_commands curl jq tar flock install systemctl id find awk

    # --- 2. Lockfile: previene ejecuciones concurrentes ---
    acquire_lock

    # --- 3. Arquitectura y última versión disponible ---
    local arch
    arch="$(detect_kavita_arch)"
    get_latest_release "${arch}"

    # --- 4. Instalación atómica con symlink de releases ---
    install_kavita_release

    # --- 5. Usuario de sistema y permisos ---
    setup_user_and_permissions

    # --- 6. Servicio systemd ---
    create_systemd_service

    # --- 7. Arranque ---
    enable_and_start_service

    # --- 8. Verificación ---
    post_checks
}

main "$@"
