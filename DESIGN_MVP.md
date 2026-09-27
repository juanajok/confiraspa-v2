# Diseño del MVP — Confiraspa como producto

> Estado: propuesta de diseño previa a implementación.
> Base: `BACKLOG.md` + decisiones de la revisión (conservar el core Bash, aislar privilegios, no exponer `.env` como recurso genérico, trabajos observables, seguridad de LAN no confiable).

---

## 1. Alcance y criterio de "MVP terminado"

El MVP **no** es "dashboard + wizard + apps + discos" si el usuario aún necesita una terminal para empezar o no puede verificar que sus backups funcionan.

**Criterio de MVP terminado (verificable):**
1. **Primer acceso sin terminal.** Desde una imagen recién flasheada (o desde un `bootstrap` que solo requiere *un* comando inicial claramente documentado), el propietario termina el alta desde el navegador de otro dispositivo. No hay credenciales predefinidas; la cuenta admin se crea en el primer arranque.
2. **Configuración por perfiles.** El usuario elige un objetivo comprensible ("NAS familiar", "Multimedia", "Descargas", "Todo") con valores seguros por defecto y una pantalla de revisión de qué se instalará.
3. **Gestión de apps y discos.** Instalar/parar/desinstalar servicios del catálogo cerrado; detectar, formatear y montar discos (con confirmación de pérdida de datos).
4. **Estado y prueba de restauración de backups.** Ver si el backup corre, cuándo, si falló, y **probar** que un fichero/config se puede restaurar.

Fuera de alcance para la primera entrega: imagen flash-ready completa (pi-gen), integraciones de nube nuevas, app store abierto con Docker, multi-usuario.

---

## 2. Principios de diseño

1. **Bash como ejecutor, no como API.** La web pide **operaciones tipadas** (`instalar samba`, `programar backup`, `preparar disco <UUID>`) a un servicio que valida parámetros y llama a funciones permitidas. **Nunca** se acepta desde HTTP un nombre de script, una ruta o argumentos libres.
2. **Interfaz y privilegios separados.** FastAPI (API + frontend mismo origen) corre **sin root**; un **ejecutor privilegiado pequeño** con una lista explícita de operaciones es lo único que toca el sistema.
3. **`.env` y JSONs no son recursos editables genéricos.** Son formato de compatibilidad del core. La API maneja **campos definidos**, oculta secretos al leer, valida cada cambio, escribe atómicamente y registra *qué operación* se hizo (nunca las contraseñas).
4. **Cada cambio es un trabajo observable.** Un `POST` crea un *job*; la UI consulta estado, progreso, resultado y diagnóstico redactado. Las operaciones destructivas enseñan dispositivo, capacidad, datos que se perderán y piden confirmación específica.
5. **Seguridad para LAN no confiable.** Acceso local por defecto, cuenta admin en primer arranque, sesión protegida y **CSRF** en cambios de estado. El acceso remoto, si llega, es una vía explícita y separada (Tailscale/VPN).

Inspiración Omarchy (con matices): [updates](https://omarchy.org/manual/updates/) (una única vía de actualización), [unattended-installs](https://omarchy.org/manual/unattended-installs/) (aprovisionar sin distribuir credenciales), [system-snapshots](https://omarchy.org/manual/system-snapshots/) (recuperación visible de *config*, no de datos), [ai](https://omarchy.org/manual/ai/) (ayuda revisable, no administrador autónomo).

---

## 3. Arquitectura de procesos y privilegios

```
[ Navegador (otro dispositivo) ]
        │ HTTPS/HTTP LAN
        ▼
┌─────────────────────────────────┐
│  web (FastAPI + estáticos)      │  User=confiraspa (sin root)
│  - autenticación, sesión, CSRF  │  NoNewPrivileges=true, ProtectSystem=strict,
│  - lee/valida config tipada     │  ProtectHome=read-only, PrivateTmp=true,
│  - crea jobs, sirve la UI       │  ReadWritePaths solo para su estado
└──────────────┬──────────────────┘
               │ socket Unix /run/confiraspa/executor.sock (0660, grupo confiraspa)
               │ protocolo JSON: {operation, params} → {status, result, diagnosis_redacted}
               ▼
┌─────────────────────────────────┐
│  executor (privilegiado)        │  User=root (o capabilities mínimos)
│  - lista EXPLÍCITA de ops       │  ProtectSystem=full, PrivateTmp=true,
│  - valida params contra schema  │  memoria/CPU limitadas, sin red
│  - llama a funciones permitidas │  (la web es la única que habla red)
└─────────────────────────────────┘
```

**Reglas del executor:**
- Cada `operation` mapea a **una** función/script del core con **argumentos fijos** derivados de parámetros validados (no de texto libre).
- La lista blanca es cerrada y versionada: `app.install`, `app.uninstall`, `app.start`, `app.stop`, `storage.prepare`, `storage.mount`, `backup.run`, `backup.restore`, `system.update`, `setup.apply`, `user.set_password`, etc.
- El executor **redacta** la salida (nunca devuelve contraseñas ni tokens) antes de responder.
- Toda operación es **idempotente y comprobable**: reutiliza los scripts ya auditados (`install.sh --only`, `20-storage.sh`, `backup_*.sh`, `restore_apps.sh`) que ya son idempotentes y tienen tests.

---

## 4. Modelo de configuración (esquema tipado)

El core sigue leyendo `.env` + `configs/static/*.json`. La API no los expone directamente; traduce entre el **esquema tipado** y esos ficheros.

```yaml
system:
  hostname: string
  timezone: string
  user: string                    # cuenta admin
  password: write-only            # NUNCA se devuelve en GET
  ssh_port: int (1..65535)
storage:
  devices: [{ uuid, path, role: library|downloads|backup, fstype }]
  mounts: [{ uuid, path, options }]
apps:
  enabled: [ "samba", "plex", "transmission", "sonarr", ... ]   # solo IDs del catálogo
  config: { <campos específicos por app, validados> }
profiles:
  nas_familiar: { apps: [...], defaults: {...} }
  multimedia:  { apps: [...], defaults: {...} }
backup:
  schedule: cron-expr
  retention: int
  destinations: [ { type: local|rclone, path } ]
```

**Garantías:**
- Escritura **atómica** (temp + rename) sobre `.env` y JSONs, igual que `20-storage.sh` hace con `fstab`.
- Validación de cada campo (tipos, rangos, allowlist) antes de escribir; reutiliza/endurece `validators.sh`.
- **Audit log** registra operación + resultado, **sin valores sensibles**.

---

## 5. Modelo de trabajos (jobs)

Toda mutación = un job:

```json
{
  "id": "j_8f3a…",
  "operation": "app.install",
  "params": { "app_id": "plex" },
  "status": "pending|running|success|failed|warning",
  "progress": 0.0..1.0,
  "result": { … },
  "diagnosis_redacted": "…",     // sin secretos
  "created_at": "…", "finished_at": "…"
}
```

- La UI crea el job (`202 Accepted` + `Location: /api/v1/jobs/{id}`) y hace *poll*.
- Los jobs persisten (SQLite o ficheros) para que un reinicio no los pierda.
- **Confirmación destructiva**: `storage.prepare` (formatear) devuelve primero un resumen `{device, capacity, data_to_lose}` y exige un `confirm_token` en el `POST` de ejecución.

---

## 6. Contrato API (v1, esqueleto inicial)

```
# Auth y sesión
POST /api/v1/auth/login            {user, password} → session cookie + CSRF token
POST /api/v1/auth/logout
GET  /api/v1/auth/session          → quién soy, first_boot?

# Sistema y estado
GET  /api/v1/system                → hostname, versión, uptime, CPU/RAM/disk/temp, servicios up/down
POST /api/v1/system/update         → job: actualización unificada (comprueba → backup config → migra → instala)

# Catálogo cerrado de apps
GET  /api/v1/apps                  → lista del catálogo + estado instalado
POST /api/v1/apps/{id}/install     → job (id ∈ catálogo; 404/400 si no)
POST /api/v1/apps/{id}/uninstall   → job
POST /api/v1/apps/{id}/start|stop|restart → job
GET  /api/v1/apps/{id}/logs        → logs redactados

# Almacenamiento
GET  /api/v1/storage/devices       → blkid: dispositivos, tamaño, UUID, montado
POST /api/v1/storage/{uuid}/prepare → resumen de pérdida de datos (requiere confirm_token en el siguiente)
POST /api/v1/storage/{uuid}/mount  → job
POST /api/v1/storage/{uuid}/unmount→ job

# Setup / perfiles
GET  /api/v1/profiles              → perfiles disponibles + qué instalarían
POST /api/v1/setup/apply           → job: aplica el perfil/config del wizard (crea usuario, monta, instala apps)

# Backups
GET  /api/v1/backup/status         → último resultado, próximos, retención
POST /api/v1/backup/run            → job
POST /api/v1/backup/restore/{app}  → job (restaura una app concreta)
GET  /api/v1/backup/restore/test   → job: prueba de restauración (restaura a tmp y verifica)

# Jobs
GET  /api/v1/jobs/{id}             → estado/progreso/resultado
```

**Regla de oro:** `id` y `uuid` deben pertenecer a catálogos/allowlists del servidor; **ningún endpoint construye comandos de shell a partir de texto del usuario**.

---

## 7. Flujos de usuario

### 7.1 Primer arranque (sin terminal)
1. Flashear imagen (o `bootstrap` documentado con *un* comando).
2. Desde otro dispositivo, abrir `http://raspberrypi.local`.
3. Wizard: idioma → crear cuenta admin → elegir perfil → revisar → aplicar (job).
4. El sistema aplica todo (usuario, discos, apps, firewall, backups) y muestra progreso.

### 7.2 Configuración por perfiles
- Perfil = conjunto de apps + defaults seguros (ej. `nas_familiar` = Samba con usuario + backups locales).
- Pantalla de **revisión** antes de aplicar (qué se instalará, qué discos se tocarán, qué credenciales se crearán — sin mostrarlas en claro).

### 7.3 Gestión de apps
- Catálogo cerrado (los ~15 servicios que Confiraspa ya sabe gestionar).
- "Instalar Plex" → job → estado/logs. Nunca un "comando libre".

### 7.4 Gestión de discos
- Listar dispositivos → elegir → ver **qué se perderá** → confirmar → formatear/montar (job).
- Asignar rol (biblioteca/descargas/backup).

### 7.5 Backup y restauración
- Dashboard muestra: último backup, resultado, próximos, retención.
- "Probar restauración": restaura a un tmp y verifica (sin tocar producción).

### 7.6 Actualización
- Botón "Actualizar" = flujo único: comprobar versiones → snapshot de config → aplicar (migraciones si aplican) → verificar. No comandos inconexos.

---

## 8. Seguridad

| Ámbito | Decisión |
|---|---|
| **Autenticación** | Cuenta admin creada en primer arranque (sin credenciales predefinidas); contraseña con hash (argon2/bcrypt). |
| **Sesión** | Cookie `HttpOnly + Secure + SameSite=Strict`, con rotación de token. |
| **CSRF** | Token CSRF obligatorio en `POST/PUT/DELETE` (doble submit o `Origin`/`Referer` + token), según [OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html). |
| **Privilegios** | Web **sin root**; executor privilegiado con allowlist y parámetros validados. Véase `systemd.exec` ([man](https://manpages.debian.org/testing/systemd/systemd.exec.5.en.html)): `NoNewPrivileges`, `ProtectSystem`, `ProtectHome`, `PrivateTmp`, restricción de memoria/CPU, sin red en el executor. |
| **Exposición** | Bind a LAN por defecto; sin NAT/port-forwarding. Acceso remoto solo por Tailscale/VPN (vía separada). |
| **Secretos** | Write-only en la API; redactados en logs y jobs; `.env`/JSONs con permisos mínimos (0600/0640) y escritura atómica. |
| **Errores** | Mensajes genéricos (no filtrar rutas/estado interno al cliente); diagnóstico completo solo en logs del servidor. |

---

## 9. Criterios de aceptación verificables (DoD del MVP)

1. Imagen/bootstrap → alta completa desde navegador, **cero terminal** (salvo el comando inicial documentado).
2. Elegir "NAS familiar" → Samba activo con el usuario creado; se puede acceder a un share desde otro equipo.
3. "Instalar Plex" → job completado, Plex accesible en `:32400`, estado visible.
4. "Preparar disco" → muestra dispositivo/capacidad/datos-a-perder, exige confirmación, y monta en la ruta correcta.
5. Backup programado → el dashboard muestra estado; "probar restauración" restaura y verifica **sin tocar producción**.
6. Un `GET` de cualquier recurso **nunca** devuelve contraseñas/tokens.
7. Un `POST` con `app_id` fuera del catálogo (o un intento de inyectar un nombre de script) es **rechazado** con 400/404.
8. Un `POST` cross-site sin token CSRF es **rechazado**.
9. Toda operación es **idempotente** (re-ejecutar no rompe) y su resultado es **comprobable** (logs/job + tests).

---

## 10. Fuera de alcance (entregas posteriores)

- Imagen flash-ready con `pi-gen` (P2.3 del backlog).
- App store abierto / Docker (P3.4).
- Multi-usuario y roles finos (P2.5).
- Agente LLM autónomo (P1.3): primero solo diagnóstico de solo-lectura + propuestas revisables.
- Integraciones de nube nuevas (rclone se mantiene como está).

---

## Siguiente paso de implementación

1. **Spike del executor**: socket Unix + allowlist de operaciones + un script core conectado (p. ej. `app.install` → `install.sh --only`), con el sistema de jobs.
2. **Esqueleto FastAPI**: auth/sesión/CSRF + `GET /api/v1/system` y `GET /api/v1/apps` (solo lectura primero).
3. **Primer flujo end-to-end**: `setup/apply` con un perfil mínimo, para validar el modelo de trabajos y el aislamiento de privilegios.
