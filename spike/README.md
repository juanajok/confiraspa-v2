# Spike del executor — Confiraspa MVP

Prueba de concepto del modelo de privilegios del MVP (`DESIGN_MVP.md`):
**web sin root → socket Unix → executor privilegiado con allowlist**.

## Qué demuestra

- Una petición web **no puede** convertirse en ejecución fuera de la allowlist
  (operaciones con esquema estricto de parámetros; sin comandos/rutas/args libres).
- Jobs **persistentes** (SQLite) con estados `pending → running → success|failed`,
  límite de concurrencia (1 operación a la vez) y marcado de `running` obsoleto
  tras reinicio.
- Salida **redactada** (secretos) y **truncada** (límite de tamaño); códigos de
  salida conservados.

## Estructura

| Fichero | Rol |
|---|---|
| `jobs.py` | Store de jobs (SQLite), compartido por API y executor |
| `executor.py` | Servidor socket Unix + allowlist + ejecución (privilegiado) |
| `api.py` | API HTTP mínima (sin root) que habla con el executor |
| `test_spike.sh` | 10 pruebas negativas |

## Ejecutar

```bash
cd spike
bash test_spike.sh
```

Los tests arrancan executor y API en segundo plano y cubren: permisos del socket,
app_id desconocido, instalación del catálogo, redacción, truncado, parámetros
extra, tipo incorrecto, operación desconocida, límite de concurrencia y
persistencia tras reinicio.

## Nota de spike

- `app.install` mapea a un **stub** (`echo` + `sleep`). En producción, la línea
  marcada con `STUB` pasa a ser `["bash", "install.sh", "--only", app]`.
- El catálogo es `CATALOG = {"plex"}` (un único ID), como pide el alcance del spike.
- Se usa stdlib de Python (sin FastAPI/uvicorn) para no añadir dependencias al
  spike; la implementación real usará FastAPI según el diseño.
- El socket se deja `0660`; en producción el grupo será `confiraspa` y la web
  pertenecerá a ese grupo.
