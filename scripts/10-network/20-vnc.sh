#!/usr/bin/env bash
# scripts/10-network/20-vnc.sh
# Configuración idempotente de VNC con soporte dual Wayland/X11
# v7.2 - Production Hardened Edition

set -euo pipefail
IFS=$'\n\t'

# --- CABECERA UNIVERSAL ---
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly REPO_ROOT
source "${REPO_ROOT}/lib/utils.sh"
source "${REPO_ROOT}/lib/validators.sh"

[[ -f "${REPO_ROOT}/.env" ]] && source "${REPO_ROOT}/.env"

# --- CONSTANTES ---
readonly VNC_USER="${SYS_USER:-pi}"
readonly VNC_PORT_X11="5901"
readonly VNC_PORT_WAYLAND="5900"

# ===========================================================================
# DETECCIÓN DE BACKEND
# ===========================================================================
detect_display_server() {
    if [[ -f /etc/xdg/wayfire.ini ]] || [[ -f /etc/xdg/labwc/rc.xml ]]; then
        echo "wayland"
    elif ps -e | grep -qE 'wayfire|labwc'; then
        echo "wayland"
    else
        echo "x11"
    fi
}

# ===========================================================================
# WAYLAND → WAYVNC
# ===========================================================================
setup_wayvnc() {
    log_info "Configurando VNC para entorno Wayland..."

    ensure_package "wayvnc"

    local home_dir
    home_dir=$(getent passwd "${VNC_USER}" | cut -d: -f6)
    local config_dir="${home_dir}/.config/wayvnc"
    local config_file="${config_dir}/config"
    local service_file="/etc/systemd/system/wayvnc.service"
    local uid
    uid=$(id -u "${VNC_USER}")

    if [[ "${DRY_RUN:-false}" == "false" ]]; then
        execute_cmd "mkdir -p '${config_dir}'" "Creando directorio config WayVNC"

        log_info "Generando configuración WayVNC..."

        cat <<EOF > "${config_file}"
address=0.0.0.0
port=${VNC_PORT_WAYLAND}
enable_auth=true
username=${VNC_USER}
password=${SYS_PASSWORD:-raspberry}
EOF

        chown -R "${VNC_USER}:${VNC_USER}" "${config_dir}"
        chmod 600 "${config_file}"

        log_info "Instalando servicio systemd WayVNC..."

        local tmp
        tmp=$(mktemp)

        cat <<EOF > "${tmp}"
[Unit]
Description=WayVNC Server
After=graphical.target
Requires=graphical.target

[Service]
Type=simple
User=${VNC_USER}
Environment=XDG_RUNTIME_DIR=/run/user/${uid}
ExecStartPre=/bin/sh -c 'while [ ! -e \$XDG_RUNTIME_DIR/wayland-0 ]; do sleep 1; done'
ExecStart=/usr/bin/wayvnc --config ${config_file}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

        if [[ ! -f "${service_file}" ]] || ! cmp -s "${tmp}" "${service_file}"; then
            execute_cmd "cp '${tmp}' '${service_file}'" "Instalando servicio WayVNC"
            execute_cmd "systemctl daemon-reload" "Recargando systemd"
        else
            log_info "Servicio WayVNC sin cambios."
        fi

        rm -f "${tmp}"

        execute_cmd "systemctl enable wayvnc" "Habilitando WayVNC"
        execute_cmd "systemctl restart wayvnc" "Arrancando WayVNC"
    else
        log_success "[DRY-RUN] Se configuraría WayVNC en puerto ${VNC_PORT_WAYLAND}"
    fi
}

# ===========================================================================
# X11 → TIGERVNC
# ===========================================================================
setup_tigervnc() {
    log_info "Configurando VNC para entorno X11 (TigerVNC)..."

    ensure_package "tigervnc-standalone-server"
    ensure_package "tigervnc-common"

    local home_dir
    home_dir=$(getent passwd "${VNC_USER}" | cut -d: -f6)
    local vnc_dir="${home_dir}/.vnc"
    local passwd_file="${vnc_dir}/passwd"
    local service_file="/etc/systemd/system/tigervnc@.service"

    if [[ "${DRY_RUN:-false}" == "false" ]]; then
        execute_cmd "install -d -o ${VNC_USER} -g ${VNC_USER} -m 700 '${vnc_dir}'" "Preparando .vnc"

        if [[ ! -f "$passwd_file" ]]; then
            log_info "Configurando contraseña TigerVNC..."
            printf '%s\n' "${SYS_PASSWORD:-raspberry}" | vncpasswd -f > "$passwd_file"
            chown "${VNC_USER}:${VNC_USER}" "$passwd_file"
            chmod 600 "$passwd_file"
        fi

        cat <<EOF > "${vnc_dir}/xstartup"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startlxde-pi
EOF

        chmod +x "${vnc_dir}/xstartup"
        chown "${VNC_USER}:${VNC_USER}" "${vnc_dir}/xstartup"

        local tmp
        tmp=$(mktemp)

        cat <<EOF > "${tmp}"
[Unit]
Description=TigerVNC Server on display %i
After=network.target

[Service]
Type=simple
User=${VNC_USER}
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver :%i -geometry 1280x720 -depth 16 -localhost no -fg
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

        if [[ ! -f "${service_file}" ]] || ! cmp -s "${tmp}" "${service_file}"; then
            execute_cmd "cp '${tmp}' '${service_file}'" "Instalando servicio TigerVNC"
            execute_cmd "systemctl daemon-reload" "Recargando systemd"
        else
            log_info "Servicio TigerVNC sin cambios."
        fi

        rm -f "${tmp}"

        execute_cmd "systemctl enable tigervnc@1" "Habilitando TigerVNC"
        execute_cmd "systemctl restart tigervnc@1" "Arrancando TigerVNC"
    else
        log_success "[DRY-RUN] Se configuraría TigerVNC en puerto ${VNC_PORT_X11}"
    fi
}

# ===========================================================================
# MAIN
# ===========================================================================
main() {
    log_section "Configuración de Acceso Remoto VNC"

    validate_root
    require_system_commands systemctl ps grep dpkg-query

    # Eliminar RealVNC si existe
    if dpkg -l | grep -q realvnc-vnc-server; then
        log_warning "Eliminando RealVNC..."
        execute_cmd "systemctl stop vncserver-x11-serviced.service || true"
        execute_cmd "apt-get purge -y realvnc-vnc-server"
    fi

    # Detectar backend
    local backend
    backend=$(detect_display_server)
    log_info "Backend detectado: ${backend^^}"

    local port
    if [[ "$backend" == "wayland" ]]; then
        setup_wayvnc
        port=$VNC_PORT_WAYLAND
    else
        setup_tigervnc
        port=$VNC_PORT_X11
    fi

    # Resultado
    local ip
    ip=$(get_ip_address)

    log_success "VNC operativo sobre ${backend}."
    log_info "Acceso: ${ip}:${port}"
    log_warning "Firewall: asegúrate de permitir el puerto ${port} en UFW."

    if [[ "$backend" == "wayland" ]]; then
        log_info "Remmina → Security: TLS o None"
    fi
}

main "$@"