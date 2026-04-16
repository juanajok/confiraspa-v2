#!/usr/bin/env bash
# =============================================================================
# scripts/40-maintenance/configurar_swap_zswap.sh
# Configura swap óptimo (ZSWAP + Swap File en NVMe) para Raspberry Pi 5 (4GB)
#
# Parte del framework Confiraspa
# Autor: Juanjo (asistido por Claude)
# Versión: 5.0 — soporte initramfs para carga temprana de módulos,
#                 fallback a built-in si no hay vía segura de carga
#
# Lógica de selección de compresor/zpool:
#   1. Si el módulo es built-in → se usa directamente (sin dependencias)
#   2. Si es loadable + initramfs activo → se inyecta en initramfs
#   3. Si es loadable + NO hay initramfs → se descarta y se usa el fallback
#      built-in (activar initramfs es demasiado invasivo para un script de swap)
#
# Uso (a través del instalador):
#   sudo ./install.sh --only configurar_swap_zswap
#
# Uso directo (con opciones avanzadas):
#   sudo ./scripts/40-maintenance/configurar_swap_zswap.sh [--swap-size 4G] \
#        [--swappiness 45] [--dry-run] [--rollback]
# =============================================================================

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
readonly SWAPFILE_PATH="/swapfile"
readonly SYSCTL_CONF="/etc/sysctl.d/99-swap-optimization.conf"
readonly FSTAB_PATH="/etc/fstab"
readonly SWAP_BACKUP_BASE="/var/log/confiraspa/backups"
readonly INITRAMFS_MODULES="/etc/initramfs-tools/modules"
readonly CONFIRASPA_INITRAMFS_MARKER="# --- BEGIN CONFIRASPA ZSWAP ---"
readonly CONFIRASPA_INITRAMFS_MARKER_END="# --- END CONFIRASPA ZSWAP ---"

# Valores por defecto (sobreescribibles con --swap-size / --swappiness)
readonly DEFAULT_SWAP_SIZE="4G"
readonly DEFAULT_SWAPPINESS=45
readonly DEFAULT_DIRTY_RATIO=10
readonly DEFAULT_DIRTY_BG_RATIO=5

# ===========================================================================
# VARIABLES (modificadas por parse_args / resolución en main)
# ===========================================================================
SWAP_SIZE=""
SWAPPINESS=""
DRY_RUN="${DRY_RUN:-false}"
ROLLBACK=false

# Ruta real de cmdline.txt — resuelta en resolver_cmdline_path().
# No es readonly porque puede caer a /boot/cmdline.txt en instalaciones antiguas.
CMDLINE_PATH="/boot/firmware/cmdline.txt"

# Calculadas en comprobar_modulos_kernel — vacías hasta entonces
ZSWAP_COMPRESSOR=""
ZSWAP_ZPOOL=""
# Módulos que requieren inyección en initramfs para carga temprana
MODULES_INITRAMFS=()
# true si el sistema tiene initramfs habilitado y funcional
INITRAMFS_DISPONIBLE=false

# ===========================================================================
# HANDLERS
# ===========================================================================
on_error() {
    local exit_code="${1:-1}"
    local line_no="${BASH_LINENO[0]:-unknown}"
    local source_file="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

    log_error "Error en '$(basename "${source_file}")' (línea ${line_no}, exit code ${exit_code})."
    log_error "Si el sistema quedó inconsistente, ejecuta: sudo ${SCRIPT_NAME} --rollback"
    exit "${exit_code}"
}

# ===========================================================================
# ARGUMENTOS
# ===========================================================================
parse_args() {
    SWAP_SIZE="${DEFAULT_SWAP_SIZE}"
    SWAPPINESS="${DEFAULT_SWAPPINESS}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --swap-size)
                SWAP_SIZE="${2:?'--swap-size requiere un valor (ej: 4G)'}"
                if ! [[ "$SWAP_SIZE" =~ ^[0-9]+[gGmM]$ ]]; then
                    log_error "--swap-size debe tener formato NúmeroUnidad (ej: 4G, 512M)"
                    exit 1
                fi
                shift 2
                ;;
            --swappiness)
                SWAPPINESS="${2:?'--swappiness requiere un valor (0-100)'}"
                if ! [[ "$SWAPPINESS" =~ ^[0-9]+$ ]] || (( SWAPPINESS > 100 )); then
                    log_error "--swappiness debe ser un entero entre 0 y 100"
                    exit 1
                fi
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --rollback)
                ROLLBACK="true"
                shift
                ;;
            -h|--help)
                mostrar_ayuda
                exit 0
                ;;
            *)
                log_error "Argumento desconocido: $1"
                mostrar_ayuda
                exit 1
                ;;
        esac
    done
    export DRY_RUN
}

mostrar_ayuda() {
    cat <<EOF
Uso: sudo ${SCRIPT_NAME} [OPCIONES]

Configura swap óptimo (ZSWAP + Swap File) para Raspberry Pi 5 con NVMe.

Estrategia de selección de compresor/zpool:
  - Prefiere módulos built-in (no dependen de nada para arrancar).
  - Si el módulo preferido es loadable y el sistema tiene initramfs activo,
    lo inyecta en initramfs para carga temprana.
  - Si no hay initramfs, cae al módulo built-in (lzo para compresor).

Opciones:
  --swap-size SIZE    Tamaño del swap file (defecto: ${DEFAULT_SWAP_SIZE})
                      Formato: NúmeroUnidad, ej: 4G, 2G, 512M
  --swappiness N      Valor de vm.swappiness 0-100 (defecto: ${DEFAULT_SWAPPINESS})
  --dry-run           Simula sin ejecutar cambios
                      (también se hereda de install.sh vía variable de entorno)
  --rollback          Restaura los ficheros de configuración del último backup
  -h, --help          Muestra esta ayuda

Ejemplos:
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} --swap-size 2G --swappiness 30
  sudo ./${SCRIPT_NAME} --dry-run
  sudo ./${SCRIPT_NAME} --rollback
EOF
}

# ===========================================================================
# DETECCIÓN DE MÓDULOS DEL KERNEL
# ===========================================================================

# Comprueba si un módulo está disponible, ya sea built-in o como .ko loadable.
# Retorna 0 si está disponible, 1 si no.
# Escribe a stdout: "builtin", "loadable", o "absent".
modulo_disponible() {
    local modulo="$1"
    local kernel_version
    kernel_version="$(uname -r)"
    local builtin_file="/lib/modules/${kernel_version}/modules.builtin"

    # 1. ¿Está built-in en el kernel?
    # modules.builtin lista rutas como kernel/crypto/zstd.ko — buscamos el nombre
    if [[ -f "${builtin_file}" ]] && grep -q "/${modulo}\.ko" "${builtin_file}" 2>/dev/null; then
        echo "builtin"
        return 0
    fi

    # 2. ¿Está ya cargado en el kernel en ejecución?
    if grep -qw "^${modulo}" /proc/modules 2>/dev/null; then
        echo "loadable"
        return 0
    fi

    # 3. ¿Existe como módulo .ko cargable?
    if modprobe -n -q "${modulo}" 2>/dev/null; then
        echo "loadable"
        return 0
    fi

    echo "absent"
    return 1
}

# Comprueba si initramfs está activo en el sistema.
# RPi OS no usa initramfs por defecto — solo está activo si:
#   1. Existe /etc/initramfs-tools/ (herramientas instaladas)
#   2. config.txt tiene una línea 'initramfs' que lo carga
#   3. Existe al menos un archivo initramfs en /boot/firmware/
comprobar_initramfs() {
    log_info "=== Comprobación de initramfs ==="

    INITRAMFS_DISPONIBLE=false

    # ¿Están instaladas las herramientas?
    if [[ ! -d /etc/initramfs-tools ]]; then
        log_info "initramfs-tools no está instalado."
        return 0
    fi

    if ! command -v update-initramfs &>/dev/null; then
        log_info "update-initramfs no disponible."
        return 0
    fi

    # ¿Existe al menos un initramfs generado?
    local initramfs_count
    initramfs_count="$(find /boot/firmware/ /boot/ -maxdepth 1 -name 'initrd*' -o -name 'initramfs*' 2>/dev/null | wc -l)"
    if [[ "$initramfs_count" -eq 0 ]]; then
        log_info "No se encontraron imágenes initramfs en /boot/firmware/ ni /boot/."
        log_info "initramfs no está activo en este sistema."
        return 0
    fi

    # ¿config.txt lo referencia?
    local config_txt="/boot/firmware/config.txt"
    if [[ ! -f "$config_txt" ]]; then
        config_txt="/boot/config.txt"
    fi

    if [[ -f "$config_txt" ]] && grep -qi '^initramfs\b' "$config_txt" 2>/dev/null; then
        INITRAMFS_DISPONIBLE=true
        log_info "initramfs activo: herramientas instaladas, imagen presente, config.txt lo carga."
    else
        log_info "initramfs-tools instalado e imagen presente, pero config.txt no lo carga."
        log_info "No se activará initramfs automáticamente (demasiado invasivo)."
    fi
}

# ===========================================================================
# RESOLUCIÓN DE RUTAS
# ===========================================================================

resolver_cmdline_path() {
    if [[ -f "${CMDLINE_PATH}" ]]; then
        log_info "cmdline.txt encontrado en: ${CMDLINE_PATH}"
        return 0
    fi

    if [[ -f /boot/cmdline.txt ]]; then
        CMDLINE_PATH="/boot/cmdline.txt"
        log_warning "Usando fallback: ${CMDLINE_PATH}"
        return 0
    fi

    log_error "No se encuentra cmdline.txt en ninguna ruta conocida."
    exit 1
}

# ===========================================================================
# COMPROBACIONES PREVIAS
# ===========================================================================

comprobar_hardware() {
    log_info "=== Comprobación de hardware ==="

    if [[ ! -f /proc/device-tree/model ]]; then
        log_error "No se detecta /proc/device-tree/model. ¿Es esto una Raspberry Pi?"
        exit 1
    fi
    local modelo
    modelo="$(tr -d '\0' < /proc/device-tree/model)"
    log_info "Modelo detectado: ${modelo}"

    local ram_kb ram_gb
    ram_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    ram_gb="$(awk "BEGIN {printf \"%.1f\", ${ram_kb}/1048576}")"
    log_info "RAM total: ${ram_gb} GiB"
    log_info "Arquitectura: $(uname -m)"
}

comprobar_filesystem() {
    log_info "=== Comprobación de filesystem ==="

    local fs_type
    fs_type="$(findmnt -n -o FSTYPE /)"
    log_info "Filesystem raíz: ${fs_type}"

    if [[ "$fs_type" == "btrfs" ]]; then
        log_error "Filesystem btrfs detectado. fallocate no funciona con CoW."
        log_error "Alternativa: usa 'truncate -s ${SWAP_SIZE} ${SWAPFILE_PATH}' o"
        log_error "desactiva CoW con 'chattr +C' antes de crear el swapfile."
        exit 1
    fi

    if [[ "$fs_type" != "ext4" ]]; then
        log_warning "Filesystem '${fs_type}' detectado (no es ext4)."
        log_warning "fallocate podría no funcionar correctamente. Se usará dd como fallback."
    fi
}

comprobar_nvme() {
    log_info "=== Comprobación de NVMe ==="

    if ! lsblk -d -o NAME,TRAN 2>/dev/null | grep -qi nvme; then
        log_warning "No se detecta disco NVMe. El script continuará, pero el"
        log_warning "rendimiento del swap será menor si se usa SD o USB."
    else
        local nvme_dev
        nvme_dev="$(lsblk -d -o NAME,TRAN | awk '/nvme/ {print $1; exit}')"
        log_info "NVMe detectado: /dev/${nvme_dev}"
    fi
}

comprobar_modulos_kernel() {
    log_info "=== Comprobación de módulos del kernel ==="

    if [[ -d /sys/module/zswap ]]; then
        local zswap_enabled
        zswap_enabled="$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo 'N')"
        log_info "ZSWAP ya cargado. Habilitado: ${zswap_enabled}"
    else
        log_info "ZSWAP no está cargado actualmente (se configurará en cmdline.txt)"
    fi

    MODULES_INITRAMFS=()

    # --- Elegir compresor ---
    # Lógica de decisión:
    #   zstd built-in         → usar zstd (caso ideal)
    #   zstd loadable + initramfs → usar zstd, inyectar en initramfs
    #   zstd loadable sin initramfs → caer a lzo (built-in, sin race condition)
    #   zstd absent           → caer a lzo
    local compressor_elegido=""
    local compressor_estado
    compressor_estado="$(modulo_disponible zstd)" || true

    case "${compressor_estado}" in
        builtin)
            compressor_elegido="zstd"
            log_info "Compresor zstd: built-in en el kernel (ideal, sin dependencias de arranque)"
            ;;
        loadable)
            if [[ "${INITRAMFS_DISPONIBLE}" == true ]]; then
                compressor_elegido="zstd"
                MODULES_INITRAMFS+=("zstd")
                log_info "Compresor zstd: loadable. Se inyectará en initramfs para carga temprana."
            else
                compressor_elegido="lzo"
                log_warning "Compresor zstd existe como módulo pero NO hay initramfs activo."
                log_warning "Sin initramfs, el kernel no puede cargar zstd a tiempo al arrancar"
                log_warning "(race condition: cmdline.txt se procesa antes de montar el rootfs)."
                log_warning "Usando lzo (built-in) como compresor. Rendimiento correcto, sin riesgo."
            fi
            ;;
        *)
            compressor_elegido="lzo"
            log_info "Compresor zstd NO disponible. Usando lzo (built-in)."
            ;;
    esac

    # --- Elegir zpool ---
    # Orden de preferencia: z3fold (ratio 3:1) > zsmalloc > zbud (ratio 2:1)
    # Misma lógica: solo se usa un módulo loadable si hay initramfs para cargarlo.
    local zpool_elegido=""
    local candidato estado

    for candidato in z3fold zsmalloc zbud; do
        estado="$(modulo_disponible "${candidato}")" || true
        case "${estado}" in
            builtin)
                zpool_elegido="${candidato}"
                log_info "Zpool ${candidato}: built-in en el kernel (ideal)"
                break
                ;;
            loadable)
                if [[ "${INITRAMFS_DISPONIBLE}" == true ]]; then
                    zpool_elegido="${candidato}"
                    MODULES_INITRAMFS+=("${candidato}")
                    log_info "Zpool ${candidato}: loadable. Se inyectará en initramfs."
                    break
                else
                    log_info "Zpool ${candidato}: loadable pero sin initramfs — descartado."
                fi
                ;;
            *)
                log_info "Zpool ${candidato}: no disponible."
                ;;
        esac
    done

    if [[ -z "${zpool_elegido}" ]]; then
        log_error "No se encontró ningún zpool disponible (z3fold, zsmalloc, zbud)"
        log_error "ni built-in ni cargable vía initramfs."
        log_error "El kernel no soporta zswap en esta configuración."
        exit 1
    fi

    ZSWAP_COMPRESSOR="${compressor_elegido}"
    ZSWAP_ZPOOL="${zpool_elegido}"

    log_info "─── Configuración ZSWAP final ───"
    log_info "  compressor = ${ZSWAP_COMPRESSOR}"
    log_info "  zpool      = ${ZSWAP_ZPOOL}"
    if [[ ${#MODULES_INITRAMFS[@]} -gt 0 ]]; then
        log_info "  initramfs  = ${MODULES_INITRAMFS[*]} (se inyectarán)"
    else
        log_info "  initramfs  = no necesario (todo built-in)"
    fi
    log_info "────────────────────────────────"
}

comprobar_swap_actual() {
    log_info "=== Estado actual del swap ==="

    if swapon --show --noheadings | grep -q .; then
        log_info "Swap activo:"
        swapon --show >&2
    else
        log_info "No hay swap activo actualmente."
    fi
    log_info "Memoria actual:"
    free -h >&2
}

# ===========================================================================
# BACKUP
# ===========================================================================

hacer_backup() {
    local backup_dir="$1"
    log_info "=== Creando backups en ${backup_dir} ==="

    local archivo
    for archivo in "${CMDLINE_PATH}" "${FSTAB_PATH}"; do
        if [[ -f "$archivo" ]]; then
            execute_cmd "cp -p '${archivo}' '${backup_dir}/$(basename "${archivo}")'" \
                "Backup: ${archivo}"
        fi
    done

    if [[ -f "${SYSCTL_CONF}" ]]; then
        execute_cmd "cp -p '${SYSCTL_CONF}' '${backup_dir}/$(basename "${SYSCTL_CONF}")'" \
            "Backup: ${SYSCTL_CONF}"
    fi

    if [[ -f "${INITRAMFS_MODULES}" ]]; then
        execute_cmd "cp -p '${INITRAMFS_MODULES}' '${backup_dir}/$(basename "${INITRAMFS_MODULES}")'" \
            "Backup: ${INITRAMFS_MODULES}"
    fi

    # Estado actual — solo informativo, nunca falla.
    # Justificación del || true: estos comandos solo capturan estado para diagnóstico;
    # un fallo aquí (ej: no hay swap activo) no debe abortar el script.
    swapon --show > "${backup_dir}/swap_estado_previo.txt" 2>&1 || true
    free -h > "${backup_dir}/memoria_estado_previo.txt" 2>&1 || true

    log_success "Backups completados en: ${backup_dir}"
}

# ===========================================================================
# ROLLBACK
# ===========================================================================

ejecutar_rollback() {
    log_info "=== ROLLBACK ==="

    local ultimo_backup
    ultimo_backup="$(find "${SWAP_BACKUP_BASE}" -maxdepth 1 -name 'swap_zswap_*' \
                     -type d | sort -r | head -1)"

    if [[ -z "$ultimo_backup" ]]; then
        log_error "No se encontraron backups en ${SWAP_BACKUP_BASE}."
        exit 1
    fi
    log_info "Restaurando desde: ${ultimo_backup}"

    local rc=0
    local necesita_initramfs_update=false

    # Desactivar swap actual antes de restaurar fstab
    if swapon --show --noheadings | grep -q "${SWAPFILE_PATH}"; then
        rc=0
        execute_cmd "swapoff '${SWAPFILE_PATH}'" "Desactivando swap" || rc=$?
        if [[ $rc -ne 0 ]]; then
            # Justificación: swapoff falla si el swap ya estaba inactivo — no es un error real.
            log_warning "swapoff falló (exit ${rc}) — puede que ya estuviera inactivo."
        fi
    fi

    # Restaurar archivos de configuración
    local archivo backup_file
    for archivo in "${CMDLINE_PATH}" "${FSTAB_PATH}" "${SYSCTL_CONF}"; do
        backup_file="${ultimo_backup}/$(basename "$archivo")"
        if [[ -f "$backup_file" ]]; then
            execute_cmd "cp -p '${backup_file}' '${archivo}'" \
                "Restaurando: ${archivo}"
        fi
    done

    # Restaurar initramfs modules si había backup
    backup_file="${ultimo_backup}/$(basename "${INITRAMFS_MODULES}")"
    if [[ -f "$backup_file" ]]; then
        execute_cmd "cp -p '${backup_file}' '${INITRAMFS_MODULES}'" \
            "Restaurando: ${INITRAMFS_MODULES}"
        necesita_initramfs_update=true
    fi

    # RISK: elimina /swapfile. Mitigado: solo si no constaba en el estado
    # previo guardado al inicio, lo que prueba que lo creó este script.
    if [[ -f "${SWAPFILE_PATH}" ]] && \
       ! grep -q "${SWAPFILE_PATH}" "${ultimo_backup}/swap_estado_previo.txt" 2>/dev/null; then
        execute_cmd "rm -f '${SWAPFILE_PATH}'" \
            "Eliminando swapfile creado por Confiraspa"
    fi

    # Reactivar dphys-swapfile si estaba instalado antes
    if dpkg -l dphys-swapfile 2>/dev/null | grep -q '^ii'; then
        execute_cmd "systemctl enable dphys-swapfile" "Reactivando dphys-swapfile"
        rc=0
        execute_cmd "systemctl start dphys-swapfile" "Arrancando dphys-swapfile" || rc=$?
        if [[ $rc -ne 0 ]]; then
            # Justificación: start puede fallar si el servicio necesita config adicional
            # que fue eliminada — el usuario debe verificar manualmente.
            log_warning "dphys-swapfile start falló (exit ${rc}) — verifica manualmente."
        fi
    fi

    rc=0
    execute_cmd "sysctl --system" "Recargando parámetros sysctl" || rc=$?
    if [[ $rc -ne 0 ]]; then
        # Justificación: sysctl --system puede fallar si algún .conf tiene errores
        # de un paquete ajeno — los cambios de este script se aplicarán al reiniciar.
        log_warning "sysctl --system falló (exit ${rc}) — los cambios se aplicarán al reiniciar."
    fi

    # Regenerar initramfs si se restauró el archivo de módulos
    if [[ "${necesita_initramfs_update}" == true ]] && command -v update-initramfs &>/dev/null; then
        log_info "Regenerando initramfs para restaurar estado previo..."
        rc=0
        execute_cmd "update-initramfs -u -k all" "Regenerando initramfs" || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warning "update-initramfs falló (exit ${rc}) — la restauración se completará al reinstalar el kernel."
        fi
    fi

    log_success "Rollback completado. Reinicia para que los cambios surtan efecto."
    exit 0
}

# ===========================================================================
# IMPLEMENTACIÓN
# ===========================================================================

desactivar_dphys_swapfile() {
    log_info "=== Paso 1: Desactivar dphys-swapfile ==="

    if dpkg -l dphys-swapfile 2>/dev/null | grep -q '^ii'; then
        local rc=0

        # Justificación de los || rc=$?: dphys-swapfile swapoff/stop fallan si
        # el swap ya estaba inactivo o el servicio ya parado — no son errores reales.
        execute_cmd "dphys-swapfile swapoff" "Desactivando dphys swap" || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warning "dphys-swapfile swapoff falló (exit ${rc}) — probablemente ya inactivo."
        fi

        rc=0
        execute_cmd "systemctl stop dphys-swapfile" "Deteniendo dphys-swapfile" || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warning "systemctl stop falló (exit ${rc}) — puede que no estuviera activo."
        fi

        execute_cmd "systemctl disable dphys-swapfile" "Deshabilitando dphys-swapfile"
        log_info "dphys-swapfile desactivado (no se purga, necesario para rollback)"
    else
        log_info "dphys-swapfile no está instalado. Nada que hacer."
    fi

    if swapon --show --noheadings | grep -q .; then
        local rc=0
        # Justificación: swapoff -a puede fallar si algún proceso tiene memoria
        # mapeada en swap — en ese caso el nuevo swap se añadirá sobre el existente.
        execute_cmd "swapoff -a" "Desactivando todo swap existente" || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warning "swapoff -a falló (exit ${rc}) — puede que no hubiera swap activo."
        fi
    fi
}

crear_swapfile() {
    log_info "=== Paso 2: Crear swap file (${SWAP_SIZE}) ==="

    if [[ -f "${SWAPFILE_PATH}" ]]; then
        log_warning "Ya existe ${SWAPFILE_PATH}. Se eliminará y recreará."
        local rc=0
        # Justificación: swapoff falla si el archivo no está activo como swap.
        execute_cmd "swapoff '${SWAPFILE_PATH}'" "Desactivando swapfile existente" || rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warning "swapoff falló (exit ${rc}) — el archivo puede que no estuviera activo."
        fi
        execute_cmd "rm -f '${SWAPFILE_PATH}'" "Eliminando swapfile existente"
    fi

    local fs_type
    fs_type="$(findmnt -n -o FSTYPE /)"

    if [[ "$fs_type" == "ext4" ]]; then
        log_info "Usando fallocate (ext4 detectado)"
        execute_cmd "fallocate -l '${SWAP_SIZE}' '${SWAPFILE_PATH}'" \
            "Creando swapfile con fallocate"
    else
        local size_num="${SWAP_SIZE%[gGmM]}"
        local size_unit="${SWAP_SIZE: -1}"
        local count=0
        case "$size_unit" in
            g|G) count=$((size_num * 1024)) ;;
            m|M) count=$size_num ;;
            # No debería llegar aquí gracias a la validación en parse_args
            *) log_error "Unidad no reconocida en --swap-size."; exit 1 ;;
        esac
        log_info "Usando dd (filesystem: ${fs_type}). count=${count} bloques de 1M"
        execute_cmd "dd if=/dev/zero of='${SWAPFILE_PATH}' bs=1M count=${count} status=none" \
            "Creando swapfile con dd (${SWAP_SIZE})"
    fi

    # SECURITY: 600 — solo root puede leer/escribir el swapfile.
    # Un swapfile legible por otros usuarios expondría memoria de procesos.
    execute_cmd "chmod 600 '${SWAPFILE_PATH}'" "Protegiendo swapfile (permisos 600)"
    execute_cmd "mkswap '${SWAPFILE_PATH}'" "Formateando swapfile"
    execute_cmd "swapon '${SWAPFILE_PATH}'" "Activando swapfile"

    log_success "Swap file creado y activado: ${SWAPFILE_PATH} (${SWAP_SIZE})"
}

configurar_fstab() {
    local temp_dir="$1"
    log_info "=== Paso 3: Añadir swap a fstab ==="

    local fstab_entry="${SWAPFILE_PATH} none swap sw 0 0"

    if grep -qF "${SWAPFILE_PATH}" "${FSTAB_PATH}"; then
        log_info "La entrada ya existe en fstab. No se modifica."
        return 0
    fi

    local fstab_snippet="${temp_dir}/fstab_snippet.txt"
    printf '\n# Swap file para RPi 5 - Confiraspa\n%s\n' "${fstab_entry}" > "${fstab_snippet}"

    execute_cmd "cat '${fstab_snippet}' >> '${FSTAB_PATH}'" \
        "Añadiendo entrada swap a fstab"

    log_success "Entrada añadida a fstab"
}

configurar_zswap_cmdline() {
    local temp_dir="$1"
    log_info "=== Paso 4: Configurar ZSWAP en cmdline.txt ==="

    local cmdline_actual
    cmdline_actual="$(cat "${CMDLINE_PATH}")"

    local zswap_params="zswap.enabled=1 zswap.compressor=${ZSWAP_COMPRESSOR} zswap.zpool=${ZSWAP_ZPOOL}"

    # Eliminar parámetros zswap previos y añadir los nuevos al final
    local cmdline_nueva
    cmdline_nueva="$(echo "$cmdline_actual" | sed 's/zswap\.[a-z_]*=[^ ]*//g' | tr -s ' ')"
    cmdline_nueva="$(echo "${cmdline_nueva} ${zswap_params}" | tr -s ' ' | sed 's/^ //;s/ $//')"

    local candidate="${temp_dir}/cmdline.txt.candidate"
    printf '%s\n' "${cmdline_nueva}" > "${candidate}"

    if cmp -s "${CMDLINE_PATH}" "${candidate}"; then
        log_info "cmdline.txt sin cambios."
        return 0
    fi

    execute_cmd "cp '${candidate}' '${CMDLINE_PATH}'" \
        "Actualizando cmdline.txt (ZSWAP: compressor=${ZSWAP_COMPRESSOR}, zpool=${ZSWAP_ZPOOL})"
}

configurar_initramfs() {
    local temp_dir="$1"
    log_info "=== Paso 5: Configurar initramfs para carga temprana de módulos ==="

    # --- Caso 1: No hay módulos que inyectar ---
    if [[ ${#MODULES_INITRAMFS[@]} -eq 0 ]]; then
        log_info "Todos los módulos zswap son built-in. No se necesita initramfs."
        # Limpiar bloque Confiraspa anterior si existía
        if [[ -f "${INITRAMFS_MODULES}" ]] && \
           grep -q "${CONFIRASPA_INITRAMFS_MARKER}" "${INITRAMFS_MODULES}" 2>/dev/null; then
            log_info "Eliminando bloque Confiraspa anterior de ${INITRAMFS_MODULES}."
            local cleaned="${temp_dir}/initramfs_modules.cleaned"
            sed "/${CONFIRASPA_INITRAMFS_MARKER}/,/${CONFIRASPA_INITRAMFS_MARKER_END}/d" \
                "${INITRAMFS_MODULES}" > "${cleaned}"
            execute_cmd "cp '${cleaned}' '${INITRAMFS_MODULES}'" \
                "Limpiando bloque Confiraspa de initramfs modules"
            execute_cmd "update-initramfs -u -k all" \
                "Regenerando initramfs (limpieza)"
        fi
        return 0
    fi

    # --- Caso 2: initramfs no disponible ---
    if [[ "${INITRAMFS_DISPONIBLE}" != true ]]; then
        # Esto no debería ocurrir: comprobar_modulos_kernel ya descarta módulos
        # loadable si no hay initramfs. Pero por seguridad:
        log_warning "Se necesita initramfs para ${MODULES_INITRAMFS[*]} pero no está disponible."
        log_warning "Los módulos seleccionados deberían ser built-in — revisa la lógica."
        return 0
    fi

    # --- Caso 3: Inyectar módulos en initramfs ---
    log_info "Inyectando módulos en initramfs: ${MODULES_INITRAMFS[*]}"

    # Construir el bloque con marcadores para idempotencia
    local bloque="${temp_dir}/initramfs_bloque.txt"
    {
        echo "${CONFIRASPA_INITRAMFS_MARKER}"
        printf '%s\n' "${MODULES_INITRAMFS[@]}"
        echo "${CONFIRASPA_INITRAMFS_MARKER_END}"
    } > "${bloque}"

    # Preparar el archivo final: base sin bloque anterior + bloque nuevo
    local candidate="${temp_dir}/initramfs_modules.candidate"
    if [[ -f "${INITRAMFS_MODULES}" ]]; then
        # Eliminar bloque anterior si existe (idempotencia)
        sed "/${CONFIRASPA_INITRAMFS_MARKER}/,/${CONFIRASPA_INITRAMFS_MARKER_END}/d" \
            "${INITRAMFS_MODULES}" > "${candidate}"
    else
        touch "${candidate}"
    fi
    cat "${bloque}" >> "${candidate}"

    if [[ -f "${INITRAMFS_MODULES}" ]] && cmp -s "${INITRAMFS_MODULES}" "${candidate}"; then
        log_info "${INITRAMFS_MODULES} sin cambios."
        return 0
    fi

    execute_cmd "cp '${candidate}' '${INITRAMFS_MODULES}'" \
        "Actualizando ${INITRAMFS_MODULES} con módulos zswap"

    log_info "Regenerando initramfs (esto puede tardar 1-2 minutos)..."
    execute_cmd "update-initramfs -u -k all" \
        "Regenerando initramfs con módulos: ${MODULES_INITRAMFS[*]}"

    log_success "initramfs actualizado con: ${MODULES_INITRAMFS[*]}"
}

configurar_sysctl() {
    local temp_dir="$1"
    log_info "=== Paso 6: Configurar sysctl (swappiness y dirty ratios) ==="

    local candidate="${temp_dir}/sysctl.candidate"
    cat > "${candidate}" <<SYSCTL
# =============================================================================
# Optimización de Swap y Memoria - Confiraspa
# Generado: $(date '+%Y-%m-%d %H:%M:%S')
# RPi 5 (4GB) con NVMe + ZSWAP
# =============================================================================

# Swappiness: cuánto prefiere el kernel mover páginas al swap.
# Con ZSWAP, el swap va primero a RAM comprimida, así que un valor
# moderado (40-50) es adecuado. Más bajo = más agresivo reteniendo en RAM.
vm.swappiness=${SWAPPINESS}

# Reduce la escritura en disco agrupando escrituras sucias.
# dirty_ratio=10: fuerza flush cuando los buffers sucios alcanzan el 10% de RAM.
# dirty_background_ratio=5: empieza a escribir en background al 5%.
vm.dirty_ratio=${DEFAULT_DIRTY_RATIO}
vm.dirty_background_ratio=${DEFAULT_DIRTY_BG_RATIO}
SYSCTL

    if [[ -f "${SYSCTL_CONF}" ]] && cmp -s "${SYSCTL_CONF}" "${candidate}"; then
        log_info "${SYSCTL_CONF} sin cambios."
        return 0
    fi

    execute_cmd "cp '${candidate}' '${SYSCTL_CONF}'" \
        "Instalando configuración sysctl"
    execute_cmd "sysctl -p '${SYSCTL_CONF}'" \
        "Aplicando parámetros sysctl"

    log_success "sysctl configurado: swappiness=${SWAPPINESS}"
}

# ===========================================================================
# VERIFICACIÓN FINAL
# ===========================================================================

verificar_resultado() {
    log_info "=== Verificación final ==="

    log_info "Swap activo:"
    swapon --show >&2
    log_info "Memoria:"
    free -h >&2

    if [[ -d /sys/module/zswap ]]; then
        log_info "ZSWAP — enabled:    $(cat /sys/module/zswap/parameters/enabled)"
        log_info "ZSWAP — compressor: $(cat /sys/module/zswap/parameters/compressor)"
        log_info "ZSWAP — zpool:      $(cat /sys/module/zswap/parameters/zpool)"
    else
        log_info "ZSWAP se activará tras el próximo reinicio."
    fi

    log_info "vm.swappiness actual: $(sysctl -n vm.swappiness)"

    if [[ ${#MODULES_INITRAMFS[@]} -gt 0 ]]; then
        log_info "Módulos inyectados en initramfs: ${MODULES_INITRAMFS[*]}"
    fi

    log_info "cmdline.txt final:"
    cat "${CMDLINE_PATH}" >&2

    log_warning "ZSWAP requiere REINICIO para activarse — ejecuta: sudo reboot"
    log_info "Tras reiniciar, verifica con:"
    log_info "  grep -r . /sys/module/zswap/parameters"
    log_info "  swapon --show && free -h"
    log_info "Para deshacer: sudo ${SCRIPT_NAME} --rollback"
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    local temp_dir=""
    local backup_dir=""

    trap 'rm -rf "${temp_dir:-}"' EXIT
    trap 'on_error "$?"' ERR

    parse_args "$@"
    log_section "Configuración de Swap + ZSWAP"

    validate_root
    log_info "Parámetros: swap_size=${SWAP_SIZE}, swappiness=${SWAPPINESS}, dry_run=${DRY_RUN}"

    temp_dir="$(mktemp -d)"

    # Resolver rutas y capacidades del sistema ANTES de backup y rollback,
    # para que todo el script opere sobre los mismos valores.
    resolver_cmdline_path
    comprobar_initramfs

    # Rollback inmediato si se pidió — no necesita comprobaciones de hardware
    if [[ "${ROLLBACK}" == "true" ]]; then
        ejecutar_rollback
    fi

    # Comprobaciones previas
    comprobar_hardware
    comprobar_filesystem
    comprobar_nvme
    comprobar_modulos_kernel
    comprobar_swap_actual

    # Backup de los ficheros que vamos a modificar
    if [[ "${DRY_RUN}" != "true" ]]; then
        backup_dir="${SWAP_BACKUP_BASE}/swap_zswap_$(date +%Y%m%d_%H%M%S)"
        execute_cmd "mkdir -p '${backup_dir}'" "Creando directorio de backup"
        hacer_backup "${backup_dir}"
    fi

    # Implementación (todos los pasos respetan DRY_RUN vía execute_cmd)
    desactivar_dphys_swapfile
    crear_swapfile
    configurar_fstab "${temp_dir}"
    configurar_zswap_cmdline "${temp_dir}"
    configurar_initramfs "${temp_dir}"
    configurar_sysctl "${temp_dir}"

    if [[ "${DRY_RUN}" != "true" ]]; then
        verificar_resultado
    else
        log_success "[DRY-RUN] Simulación completada. No se realizaron cambios."
    fi

    log_success "Script finalizado correctamente."
}

main "$@"