# Backlog de Confiraspa — Evolución a producto

> Visión: convertir Confiraspa en un **producto** que permita a una persona **no técnica** configurar una Raspberry Pi como servidor doméstico completo (NAS, multimedia, torrents, backups) **sin tocar un terminal ni editar ficheros**.

---

## Fuentes de inspiración

| Proyecto | Qué aporta | Aplicación a Confiraspa |
|---|---|---|
| **Omarchy** ([omarchy.org](https://omarchy.org), [github](https://github.com/omacom/omarchy)) | Filosofía de producto: *opinionated*, *agentic*, zero-touch, manual completo, snapshots, notices | Wizard asistido, defaults sensatos, rollback, notificaciones, manual de usuario |
| **CasaOS** | Panel web, **app store** (100+ apps Docker one-click), file manager, widgets, gestión de almacenamiento | Dashboard, catálogo de apps, gestor de ficheros web |
| **Umbrel** | Servidor personal con app store + UI cuidada | Mismo patrón: catálogo de servicios + panel |
| **DietPi** | Setup optimizado de RPi: `dietpi-software` (menú instalador), `dietpi-drive_manager`, `dietpi-backup`, first-boot automático, log a RAM | Gestor de discos UI, instalador guiado, optimizaciones SD, backup integrado |

---

## Criterios de priorización

- **P0 — MVP**: lo mínimo para que sea un producto usable por no técnicos.
- **P1 — Robustez y autonomía**: que el producto "se cuide solo".
- **P2 — Experiencia completa**: catálogo rico, imagen flash-ready, documentación.
- **P3 — Optimización y pulido**: rendimiento, branding, migración de arquitectura.

> Nota: Confiraspa **ya tiene** el core (scripts bash auditados, idempotencia, `execute_cmd`, tests, firewall, backups). El backlog **reutiliza** ese core; no es un rewrite.

---

## P0 — MVP (Producto Mínimo Viable)

### P0.1 · Panel web / Dashboard
- **Inspiración:** CasaOS / Umbrel.
- **Descripción:** un panel web local (`http://raspberrypi:PORT`) que muestra el estado del servidor y da acceso a las apps.
- **Alcance:**
  - Estado en vivo: servicios up/down, CPU/RAM/temperatura, discos (uso/libre), swap.
  - Atajos a las UIs de Sonarr/Radarr/Plex/Transmission/aMule/Calibre/Kavita/Bazarr.
  - Widgets: almacenamiento, red, uptime.
- **Reutiliza:** `status_monitors.sh`, `df`/`free`/`swapon`, `systemctl`.
- **Criterio:** un usuario ve el estado y abre Plex desde el navegador, sin terminal.

### P0.2 · Wizard de configuración inicial
- **Inspiración:** Omarchy (agentic/unattended) + DietPi (first-boot).
- **Descripción:** al primer arranque, un asistente web sustituye la edición manual de `.env`.
- **Alcance:**
  - Idioma, usuario/contraseña, zona horaria.
  - Detección de discos (blkid) y asignación: biblioteca / descargas / backup.
  - Checklist visual de servicios a activar (NAS, Plex, torrents, subtítulos, *Arr, DLNA…).
  - Genera `.env` + `configs/static/*.json` con validación (reutiliza `validators.sh`).
- **Reutiliza:** `bootstrap.sh`, `20-storage.sh`, `10-users.sh`, `validate_var`.
- **Criterio:** de imagen recién flasheada a servidor configurado sin editar ningún fichero.

### P0.3 · Gestor de aplicaciones (instalar/parar/desinstalar)
- **Inspiración:** CasaOS/Umbrel (app management) + DietPi (`dietpi-software`).
- **Descripción:** instalar/desinstalar/iniciar/parar/reiniciar cada servicio desde la UI.
- **Alcance:**
  - Instalar = `install.sh --only <servicio>` (ya existe).
  - Estado + logs por servicio (`journalctl`).
  - Desinstalar con purga opcional.
- **Reutiliza:** `install.sh` (orquestador y `--only`), scripts `30-services/*`.
- **Criterio:** "Instalar Plex" con un clic; ver si arrancó y sus logs.

### P0.4 · Gestor de discos y montajes
- **Inspiración:** DietPi (`dietpi-drive_manager`).
- **Descripción:** detectar, formatear y montar discos USB desde la UI.
- **Alcance:**
  - Listar discos (blkid), formatear (ext4/ntfs), montar, asignar rol (biblioteca/descargas/backup).
  - Edita `mounts.json` + `/etc/fstab` con las mismas garantías de `20-storage.sh` (temp+merge+`findmnt --verify`+backup).
- **Reutiliza:** `20-storage.sh`, `mounts.json`.
- **Criterio:** conectar un USB y montarlo en `/media/Backup` desde el navegador.

---

## P1 — Robustez y autonomía

### P1.1 · Notificaciones
- **Inspiración:** Omarchy (Notices).
- **Descripción:** alertas push cuando algo va mal o requiere atención.
- **Alcance:** Telegram y/o email (SMTP) para: backup fallido, disco lleno, servicio caído, actualización pendiente.
- **Reutiliza:** los exit codes de `backup_rsync.sh`/`backup_cloud.sh` (issue #16), cron.
- **Criterio:** un backup que falla a las 04:00 llega al móvil del usuario.

### P1.2 · Snapshots y rollback
- **Inspiración:** Omarchy (System snapshots).
- **Descripción:** snapshot automático de config antes de cada cambio + restauración desde la UI.
- **Alcance:**
  - Snapshot de `.env` + `configs/static/*` + `/etc/fstab` + crontab antes de cada acción de la UI.
  - Rollback de una app o del sistema completo desde el panel.
- **Reutiliza:** `create_backup` (ya existe), `restore_apps.sh`, `configurar_swap_zswap.sh --rollback`.
- **Criterio:** "rompí algo, deshazlo" con un clic.

### P1.3 · Asistente / agente de configuración
- **Inspiración:** Omarchy (agentic).
- **Descripción:** un chat/agente (LLM) que conversa con el usuario y configura el sistema.
- **Alcance:** "quiero un NAS para fotos y ver pelis en la tele" → propone y activa Samba + Plex + MiniDLNA; diagnostica fallos leyendo logs.
- **Reutiliza:** la capa API del panel (P0).
- **Criterio:** el usuario describe el objetivo en lenguaje natural y el agente lo ejecuta.

### P1.4 · Actualizaciones gestionadas
- **Inspiración:** DietPi (update tool).
- **Descripción:** notificar y aplicar actualizaciones de apps y del sistema desde la UI.
- **Alcance:** comprobar versiones, actualizar servicios (re-ejecutar su script), `apt` de seguridad.
- **Reutiliza:** `00-update.sh` (unattended-upgrades ya configurado).
- **Criterio:** "hay una actualización de Sonarr, ¿la aplico?" desde el panel.

---

## P2 — Experiencia completa

### P2.1 · App store / catálogo de apps
- **Inspiración:** CasaOS/Umbrel (app store).
- **Descripción:** catálogo visual de servicios instalables (iconos, descripción, categorías), más allá de los ~15 actuales.
- **Alcance:** categorías (descarga, multimedia, NAS, nube), búsqueda, "instalar en un clic".
- **Depende de:** P0.3.
- **Criterio:** navegar un catálogo y añadir servicios sin saber qué es un paquete.

### P2.2 · Gestor de ficheros web
- **Inspiración:** CasaOS (file manager).
- **Descripción:** navegar/copiar/mover/subir/descargar ficheros del NAS desde el navegador.
- **Alcance:** vista de carpetas de biblioteca/descargas/backup, subida por arrastrar, papelera.
- **Criterio:** mover una película entre carpetas desde el móvil.

### P2.3 · Imagen flash-ready
- **Inspiración:** Omarchy (Unattended) + DietPi.
- **Descripción:** imagen de Raspberry Pi OS con Confiraspa preinstalado + wizard first-boot.
- **Alcance:** build con `pi-gen`, arranque → wizard (P0.2) → listo.
- **Depende de:** P0.2.
- **Criterio:** flashear SD, enchufar, abrir navegador.

### P2.4 · Manual de usuario
- **Inspiración:** Omarchy (manual de 51 capítulos).
- **Descripción:** guía real para no técnicos, en español, con capturas.
- **Alcance:** primeros pasos, qué hace cada servicio, qué hacer si falla, copias de seguridad, seguridad básica.
- **Criterio:** alguien sin contexto usa el producto solo con el manual.

### P2.5 · Multi-usuario y roles
- **Inspiración:** CasaOS.
- **Descripción:** usuarios con permisos (admin vs. solo-lectura de algunos shares).
- **Enlaza con:** issues #9 (Samba/rsync auth) y #10 (admin remoto).
- **Criterio:** un miembro de la familia accede a fotos pero no borra backups.

---

## P3 — Optimización y pulido

### P3.1 · Optimizaciones estilo DietPi
- **Descripción:** log a RAM (menos escritura SD), zram tuning, reducir desgaste, ajustes de I/O.
- **Reutiliza:** `configurar_swap_zswap.sh`, `logrotate.sh`, `status_monitors.sh`.
- **Criterio:** menor desgaste de SD + mejor latencia en RPi 4/5.

### P3.2 · Temas y branding
- **Inspiración:** Omarchy (themes).
- **Descripción:** identidad visual cuidada, tema claro/oscuro, logo.
- **Criterio:** el panel se siente "de producto", no de script.

### P3.3 · Monitorización externa
- **Descripción:** integración con healthchecks.io / Uptime Kuma para ver el servidor desde fuera de la LAN.
- **Enlaza con:** P1.1.
- **Criterio:** saber si el NAS está vivo estando fuera de casa.

### P3.4 · Migración a Docker/Compose (opcional, largo plazo)
- **Inspiración:** CasaOS/Umbrel.
- **Descripción:** mover los servicios a contenedores para aislamiento y catálogo real de apps.
- **Nota:** solo si se quiere el modelo "app store" completo; no es necesario para un NAS de un usuario.
- **Criterio:** decidir tras validar el MVP sobre bash (que ya funciona y está auditado).

---

## Mapa de dependencias (resumen)

```
P0.1 Dashboard ──┐
P0.2 Wizard     ├─→ P0.3 Apps ──→ P2.1 App store
P0.4 Discos     ┘
                       └──→ P1.3 Agente (sobre la API)
P0.* ──→ P1.1 Notificaciones, P1.2 Snapshots, P1.4 Updates
P0.2 ──→ P2.3 Imagen flash-ready
P0.3 + P0.4 ──→ P2.2 File manager
```

---

## Siguiente paso propuesto

Definir el **MVP (P0)** como un documento de diseño: API/contrato (endpoints que leen/escriben `.env`/JSONs y disparan los scripts existentes) + stack (FastAPI/Python o Node + frontend ligero), y validarlo antes de escribir código.
