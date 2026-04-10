
# 🚀 Confiraspa: Framework de Aprovisionamiento para Raspberry Pi

![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat-square&logo=gnu-bash)
![Raspberry Pi](https://img.shields.io/badge/Platform-Raspberry%20Pi%20OS-C51A4A?style=flat-square&logo=raspberry-pi)
![License](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)
![Status](https://img.shields.io/badge/Status-Stable-success?style=flat-square)

**Confiraspa** convierte una Raspberry Pi con Raspberry Pi OS recién instalado en un servidor doméstico completo: NAS, servidor multimedia, cliente torrent, backups automáticos en la nube y más. Solo tienes que configurar un archivo de texto y ejecutar un script.

---

## ¿Qué hace exactamente?

Al ejecutarlo, el sistema instala y configura automáticamente:

| Servicio | Puerto | Para qué sirve |
| :--- | :--- | :--- |
| **Samba** | 445 | Carpetas compartidas accesibles desde Windows/Mac/Linux |
| **Transmission** | 9091 | Cliente torrent con interfaz web |
| **Sonarr** | 8989 | Descarga y organiza series automáticamente |
| **Radarr** | 7878 | Descarga y organiza películas automáticamente |
| **Lidarr** | 8686 | Descarga y organiza música automáticamente |
| **Readarr** | 8787 | Descarga y organiza libros automáticamente |
| **Prowlarr** | 9696 | Gestiona los indexadores para toda la suite Arr |
| **Bazarr** | 6767 | Descarga subtítulos automáticamente |
| **Plex** | 32400 | Servidor multimedia con apps para TV, móvil, etc. |
| **Calibre** | 8083 | Biblioteca y servidor de e-books |
| **aMule** | 4711 | Cliente P2P (red eDonkey) |
| **Webmin** | 10000 | Panel de administración del sistema vía web |
| **XRDP** | 3389 | Escritorio remoto compatible con Windows |
| **VNC** | 5900 | Escritorio remoto alternativo |

Además configura automáticamente:
- Firewall UFW (solo acceso desde red local)
- Actualizaciones de seguridad automáticas
- Montaje de discos duros externos al arrancar
- Backups diarios locales con rsync
- Backups semanales en Google Drive con rclone
- Rotación automática de backups (conserva los 5 más recientes por servicio)
- Limpieza de descargas duplicadas

---

## Requisitos

- Raspberry Pi 3, 4 o 5
- Raspberry Pi OS (Bookworm o Bullseye), Lite o Desktop
- Un disco duro externo USB (recomendado, para la biblioteca multimedia y backups)
- Conexión a internet

---

## Puesta en marcha (primera vez)

### Paso 1 — Clonar el repositorio en la Raspberry Pi

Conéctate por SSH y ejecuta:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/juanajok/confiraspa-v2.git /opt/confiraspa
cd /opt/confiraspa
```

### Paso 2 — Preparar el entorno

```bash
sudo ./bootstrap.sh
```

Este script instala las dependencias mínimas (`jq`, `curl`), hace los scripts ejecutables y crea el archivo `.env` a partir de la plantilla.

### Paso 3 — Configurar el archivo `.env`

```bash
nano .env
```

Variables imprescindibles que debes rellenar:

| Variable | Qué poner |
| :--- | :--- |
| `SYS_USER` | Tu usuario del sistema (normalmente `pi`) |
| `SYS_PASSWORD` | Contraseña para ese usuario |
| `HOSTNAME` | Nombre que quieres darle al servidor |
| `TIMEZONE` | Tu zona horaria (ej. `Europe/Madrid`) |
| `EXTERNAL_DISK_UUID` | UUID de tu disco duro externo |
| `PATH_LIBRARY` | Punto de montaje para la biblioteca multimedia (ej. `/media/WDElements`) |
| `PATH_DOWNLOADS` | Punto de montaje para descargas (ej. `/media/DiscoDuro`) |
| `PATH_BACKUP` | Punto de montaje para backups (ej. `/media/Backup`) |
| `SMB_PASS` | Contraseña para las carpetas compartidas Samba |
| `TRANSMISSION_USER` / `TRANSMISSION_PASS` | Credenciales interfaz web Transmission |
| `PLEX_CLAIM_TOKEN` | Token de Plex (obtenerlo en plex.tv/claim, opcional) |

> **¿Cómo obtengo el UUID de mi disco?**
> ```bash
> lsblk -f
> ```
> Busca la columna `UUID` junto al nombre de tu disco (ej. `sda1`).

### Paso 4 — Ejecutar el instalador

```bash
sudo ./install.sh
```

El proceso tarda entre 15 y 30 minutos dependiendo de la conexión. Al terminar, todos los servicios estarán activos y arrancando automáticamente con el sistema.

Cada ejecución genera un log detallado en `logs/install_YYYYMMDD_HHMMSS.log`.

---

## Uso del día a día

### Reinstalar o reparar un servicio concreto

Si algo falla o quieres reinstalar solo un servicio:

```bash
sudo ./install.sh --only sonarr
sudo ./install.sh --only samba
sudo ./install.sh --only cleanup_backups
```

### Simular sin hacer cambios reales

Útil para verificar qué haría el script antes de aplicarlo:

```bash
sudo ./install.sh --dry-run
sudo ./install.sh --dry-run --only radarr
```

### Restaurar la configuración de las apps

El script `scripts/40-maintenance/restore_apps.sh` recupera la configuración de cada servicio a partir de los backups almacenados en disco. Es útil tras una reinstalación, un fallo de disco del sistema, o para migrar el servidor a una Raspberry Pi nueva.

**¿Qué restaura?**

| App | Fuente del backup | Archivos restaurados |
| :--- | :--- | :--- |
| Radarr | `/media/Backup/radarr/*.zip` | `radarr.db`, `config.xml` |
| Sonarr | `/media/Backup/sonarr/*.zip` | `sonarr.db`, `config.xml` |
| Lidarr | `/media/Backup/lidarr/*.zip` | `lidarr.db`, `config.xml` |
| Readarr | `/media/Backup/readarr/*.zip` | `readarr.db`, `config.xml` |
| Prowlarr | `/media/Backup/prowlarr/*.zip` | `prowlarr.db`, `config.xml` |
| Whisparr | `/media/Backup/whisparr/*.zip` | `whisparr2.db`, `config.xml` |
| Plex | `/media/Backup/plexmediaserver/` | `Preferences.xml` |
| rclone | `/media/Backup/rclone/` | `rclone.conf` |

El script selecciona automáticamente **el backup más reciente** disponible en cada directorio.

**Pasos para restaurar**

1. Asegúrate de que el disco de backups está montado y los backups existen:

   ```bash
   ls /media/Backup/
   ```

2. Simula primero para verificar qué se restauraría sin tocar nada:

   ```bash
   sudo ./scripts/40-maintenance/restore_apps.sh --dry-run
   ```

3. Ejecuta la restauración real:

   ```bash
   sudo ./scripts/40-maintenance/restore_apps.sh
   ```

**¿Qué hace el script internamente?**

- Detiene cada servicio antes de restaurar y lo vuelve a arrancar al terminar.
- Para los *Arr (backups en ZIP): extrae los archivos indicados en `configs/static/restore.json` y elimina los ficheros WAL de SQLite residuales (`.db-wal`, `.db-shm`) para evitar corrupción.
- Para Plex y rclone (ficheros sueltos): copia directamente desde el directorio de backup.
- Corrige `BindAddress` en `config.xml` si el backup venía configurado en `127.0.0.1` o `localhost`, cambiándolo a `*` para que la interfaz web sea accesible desde la red local.
- Aplica los permisos y propietarios correctos a todos los archivos restaurados.

> Las rutas de backup y los archivos a restaurar se configuran en `configs/static/restore.json`. Edita ese archivo si has cambiado las rutas en tu `.env`.

---

### Ver los logs de mantenimiento automático

Los trabajos programados escriben sus logs en `/var/log/`:

```bash
tail -f /var/log/backup_rsync.log      # Backup local diario
tail -f /var/log/rclone_backup.log     # Backup nube (domingos)
tail -f /var/log/cleanup_backups.log   # Rotación de backups
tail -f /var/log/clean_downloads.log   # Limpieza de descargas
tail -f /var/log/auto_update.log       # Actualizaciones del sistema
```

---

## Mantenimiento automático (cron)

Una vez instalado, el sistema se mantiene solo según este calendario:

| Frecuencia | Hora | Tarea |
| :--- | :--- | :--- |
| Diario | 04:00 | Backup local a disco externo (rsync) |
| Diario | 05:30 | Limpieza de descargas duplicadas |
| Diario | 06:00 | Actualizaciones de seguridad del sistema |
| Lunes | 03:00 | Corrección automática de permisos |
| Domingos | 04:30 | Rotación de backups (conserva los 5 más recientes) |
| Domingos | 05:00 | Backup a Google Drive (rclone) |

---

## Estructura del proyecto

```
confiraspa/
├── bootstrap.sh              # Primer arranque: instala dependencias, crea .env
├── install.sh                # Orquestador principal
├── .env                      # Tus secretos y rutas (NO se sube a GitHub)
├── .env.example              # Plantilla de configuración
├── lib/
│   ├── utils.sh              # Logging, execute_cmd, ensure_package, etc.
│   └── validators.sh         # Validaciones defensivas
├── configs/static/
│   ├── mounts.json           # Definición de discos a montar
│   ├── retention.json        # Política de retención de backups
│   ├── cloud_backups.json    # Trabajos de backup a Google Drive
│   ├── restore.json          # Qué restaurar, desde dónde y con qué permisos
│   ├── crontabs.txt          # Tareas programadas gestionadas por Confiraspa
│   └── templates/            # Plantillas de configuración (smb.conf, etc.)
├── scripts/
│   ├── 00-system/            # Actualización, usuarios, almacenamiento
│   ├── 10-network/           # Firewall, XRDP, VNC
│   ├── 30-services/          # Todos los servicios (Samba, Arr, Plex, etc.)
│   └── 40-maintenance/       # Backups, limpieza, permisos, rotación de logs
└── logs/                     # Historial de ejecuciones del instalador
```

---

## Contribuir

Al añadir nuevos scripts:
1. Usa la cabecera universal (ver cualquier script existente como referencia).
2. No hardcodees rutas ni contraseñas; usa `$REPO_ROOT` y variables de `.env`.
3. Usa `execute_cmd` para todos los comandos que modifican el sistema (así funciona el dry-run).
4. Usa `log_info`, `log_success`, `log_error` para los mensajes (nunca `echo` directo).

---

## Licencia

Este proyecto está bajo la Licencia [MIT](LICENSE).

---
*Hecho con ❤️ y mucho Bash.*
