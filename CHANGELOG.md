# Changelog

Todas las versiones notables de Confiraspa se documentan aquí.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es/1.1.0/) y el versionado [SemVer](https://semver.org/lang/es/).

---

## [1.0.0] — 2026-09-24

### Primera versión estable (auditada y endurecida)

Framework de aprovisionamiento en Bash para Raspberry Pi OS (Bookworm/Bullseye):
convierte una Raspberry Pi en un servidor doméstico completo, idempotente y con
registro estructurado.

**Servicios gestionados:** Samba (NAS), Transmission, suite *Arr (Sonarr, Radarr,
Lidarr, Readarr, Prowlarr, Whisparr, Bazarr), Plex, Calibre, Kavita, MiniDLNA,
aMule, Webmin, rsync, rclone, XRDP/VNC.

**Infraestructura:** firewall UFW (modelo LAN-only), montaje de discos por UUID
con `nofail`, usuarios/grupos, backups locales (rsync) y nube (rclone), rotación
de backups, logrotate, journald, cron gestionado por marcadores, swap/ZSWAP y
monitores Webmin.

### Seguridad y resiliencia (resultado de auditoría completa)

- **Cadena de suministro:** SHA256 fijado en Bazarr (v1.6.1) con fallo cerrado antes de `pip`.
- **Transmission:** `rpc-port` correcto (9091 LAN), `rpc-authentication-required`, whitelist RFC1918/Tailscale, y eliminada la fuga del `rpc-password` al log.
- **Backup rsync:** códigos de salida 0/1/2 (éxito/fallo/skip), retención alineada con destinos, fallo cerrado ante JSON corrupto.
- **Swap:** creación atómica (rename) + `check_disk_space` antes de `swapoff`.
- **`restore_apps`:** rechazo de symlinks y `..` en ZIP, backup previo en ficheros sueltos y rearranque del servicio ante fallo.
- **`fix_permissions`:** preserva setgid (`! -perm -2000`), blacklist + `realpath`, y `-xdev` para no cruzar mountpoints.
- **CI:** ShellCheck (acción pineada) + Gitleaks (detección de secretos en el historial).
- **Credenciales:** rotadas y `.env` purgado del historial git del repositorio público.

### Tests

Suite de tests funcionales en `tests/` (7 ficheros, ejecutables sin root):

`test_backup_rsync.sh`, `test_transmission.sh`, `test_swap_zswap.sh`,
`test_restore_apps.sh`, `test_bazarr.sh`, `test_bazarr_archive.sh`,
`test_fix_permissions.sh`.
