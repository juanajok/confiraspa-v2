

# 🚀 Confiraspa: Framework de Aprovisionamiento para Raspberry Pi

![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat-square&logo=gnu-bash)
![Raspberry Pi](https://img.shields.io/badge/Platform-Raspberry%20Pi%20OS-C51A4A?style=flat-square&logo=raspberry-pi)
![License](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)
![Status](https://img.shields.io/badge/Status-Stable-success?style=flat-square)

**Confiraspa** es un conjunto orquestado de scripts de automatización diseñado para transformar una instalación limpia de Raspberry Pi OS (Bookworm/Bullseye) en un servidor doméstico de producción robusto, seguro y mantenible.

A diferencia de los scripts tradicionales, Confiraspa aplica principios de **Ingeniería DevOps**: idempotencia, programación defensiva, gestión segura de secretos y logs estructurados.

---

## ✨ Características Principales

*   **🛡️ Seguridad Primero:** Gestión de secretos vía `.env` (no versionado), firewall, actualizaciones automáticas de seguridad y usuarios sin privilegios para servicios.
*   **🔄 Idempotencia:** Puedes ejecutar el instalador tantas veces como quieras. Si algo ya está configurado, lo verifica y continúa sin romper nada.
*   **📂 Gestión de Almacenamiento Avanzada:** Soporte nativo para múltiples discos duros, montaje automático (`fstab`) y gestión inteligente de permisos para la suite multimedia.
*   **🎬 Suite Multimedia (*Arr):** Instalación automatizada de Sonarr, Radarr, Lidarr, Prowlarr, Transmission y Plex con versiones nativas (.NET) y permisos cruzados preconfigurados.
*   **📝 Observabilidad:** Logs detallados de cada ejecución (`logs/install_YYYYMMDD.log`) y modo `--dry-run` para simular cambios antes de aplicarlos.
*   **⚡ Modularidad:** Arquitectura basada en etapas (System -> Network -> Services).

---

## 🏗️ Arquitectura del Proyecto

El proyecto sigue una estructura jerárquica y ordenada:

```text
confiraspa/
├── bootstrap.sh            # 🚀 Script de inicio (instala git, prepara entorno)
├── install.sh              # 🧠 Orquestador principal
├── .env                    # 🔐 Variables de entorno y secretos (NO VERSIONADO)
├── configs/
│   └── static/             # Definiciones JSON (mounts.json, apps.json)
├── lib/
│   ├── utils.sh            # Funciones core (log, execute_cmd)
│   └── validators.sh       # Comprobaciones defensivas (root, deps, vars)
├── scripts/
│   ├── 00-system/          # Update, Users, Storage, Fstab
│   ├── 10-network/         # Static IP, VPN, XRDP, VNC
│   └── 30-services/        # Samba, Transmission, Suite *Arr, Plex
└── logs/                   # Historial de ejecuciones
```

---

## 🚀 Inicio Rápido

### 1. Prerrequisitos
*   Una Raspberry Pi 3, 4 o 5.
*   Raspberry Pi OS (Lite o Desktop) recién instalado.
*   Conexión a internet.

### 2. Instalación
Accede por SSH a tu Raspberry Pi y ejecuta:

```bash
# 1. Clonar el repositorio
sudo apt update && sudo apt install -y git
git clone https://github.com/juanajok/confiraspa.git /opt/confiraspa

# 2. Entrar al directorio
cd /opt/confiraspa

# 3. Configurar el entorno (CRÍTICO)
cp .env.example .env
nano .env  # <--- Rellena tus contraseñas y UUIDs aquí

# 4. Iniciar la magia
sudo ./bootstrap.sh
```

---

## ⚙️ Configuración (.env)

El archivo `.env` es el corazón de la configuración. **Nunca lo subas a GitHub**.

| Variable | Descripción | Ejemplo |
| :--- | :--- | :--- |
| `SYS_USER` | Usuario principal del sistema | `pi` |
| `SYS_PASSWORD` | Contraseña para el usuario sistema | `TuPassSegura!` |
| `EXTERNAL_DISK_UUID` | UUID del disco principal | `a1b2-c3d4...` |
| `SMB_PASS` | Contraseña para compartir archivos (Samba) | `sambaSecret` |
| `ARR_USER` | Usuario para servicios multimedia | `media` |
| `DRY_RUN` | Modo simulación (`true`/`false`) | `false` |

> 💡 **Tip:** Usa `lsblk -f` para obtener los UUIDs de tus discos duros.

---

## 🛠️ Uso Avanzado

El script `install.sh` permite parámetros para un control granular:

### Modo Simulación (Dry Run)
Muestra qué comandos se ejecutarían sin hacer cambios reales. Ideal para verificar antes de desplegar.
```bash
sudo ./install.sh --dry-run
```

### Ejecutar un solo módulo
Si solo quieres reinstalar o arreglar un servicio específico (ej. Sonarr):
```bash
sudo ./install.sh --only sonarr
```
*(Nota: Esto ejecutará cualquier script que contenga "sonarr" en su nombre).*

### Logs y Depuración
Cada ejecución genera un log detallado en la carpeta `logs/`:
```bash
tail -f logs/install_20240101_120000.log
```

---

## 📦 Servicios Incluidos

| Servicio | Puerto | Descripción |
| :--- | :--- | :--- |
| **Samba** | 445 | Compartición de archivos en red local. |
| **XRDP** | 3389 | Escritorio remoto compatible con Windows. |
| **RealVNC** | 5900 | Escritorio remoto (incluso modo Headless). |
| **Transmission** | 9091 | Cliente Torrent ligero. |
| **Sonarr** | 8989 | Gestión automática de Series. |
| **Radarr** | 7878 | Gestión automática de Películas. |
| **Lidarr** | 8686 | Gestión automática de Música. |
| **Prowlarr** | 9696 | Gestión de indexadores Torrent. |
| **Plex** | 32400 | Servidor multimedia. |
| **Webmin** | 10000 | Administración del sistema vía web. |

---

## 🤝 Contribución

Las Pull Requests son bienvenidas. Por favor, sigue estos estándares:
1.  Usa la "Cabecera Universal" en los nuevos scripts.
2.  No hardcodees rutas ni contraseñas; usa variables de `$REPO_ROOT` y `.env`.
3.  Usa `log_info`, `log_error` y `execute_cmd` para mantener la consistencia en los logs.

## 📄 Licencia

Este proyecto está bajo la Licencia [MIT](LICENSE).

---
*Hecho con ❤️ y mucho Bash.*