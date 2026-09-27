# Spike del executor — Confiraspa MVP (v2, endurecido)

Prueba de concepto del modelo de privilegios del MVP (`DESIGN_MVP.md`):
**web sin root → socket Unix → executor privilegiado con allowlist**.

## Qué demuestra (v2)

- **Allowlist estricta + argumentos de lista** (sin shell, sin interpolar texto
  del usuario): app_id desconocido, operación desconocida, parámetros extra y
  tipos incorrectos se rechazan.
- **Límites antes de capturar**: body HTTP (64 KB), petición por socket
  (256 KB + timeout de conexión), salida del subprocess acotada desde el origen
  (drenada en hilo, máximo 64 KB) y timeout de ejecución por operación.
- **Secretos no persistidos**: `jobs.summarize()` solo guarda campos públicos de
  cada operación; la redacción de la salida es una *segunda* defensa.
- **Semántica de recuperación**: excepción durante la operación → `failed`;
  `running` interrumpido y `pending` huérfano → `failed` al arrancar.
- **Concurrencia**: máximo 1 operación a la vez.

## Estructura

| Fichero | Rol |
|---|---|
| `jobs.py` | Store de jobs (SQLite) + `summarize()` + recuperación de obsoletos |
| `executor.py` | Socket Unix + allowlist + ejecución acotada (privilegiado) |
| `api.py` | API HTTP mínima (sin root) + límite de body |
| `test_spike.sh` | 15 pruebas (negativas + límites + recuperación) |

## Ejecutar

```bash
cd spike
bash test_spike.sh
```

## Límites del spike (no lo confundir con un executor de producción)

1. **No hay separación real de usuarios.** API y executor corren como el mismo
   usuario en el test; `0660` es el mecanismo, pero falta una prueba con dos
   identidades reales (web vs. usuario ajeno) y un intento desde una tercera —
   en la RPi o en CI.
2. **El socket y la SQLite siguen en `/tmp` por comodidad.** En producción el
   directorio (`/run/confiraspa/`) lo crea systemd (`RuntimeDirectory=`) con
   propietario/permisos definidos; el executor ya **no** borra rutas arbitrarias
   (solo un socket obsoleto propio).
3. **`app.install` es un stub.** No llama a `install.sh` todavía; la línea de
   producción es `subprocess.run([SCRIPT, "--only", app_id], ...)` con ruta fija
   y entorno controlado. Falta validarlo contra el script real en un entorno
   recuperable.
4. **Sin autenticación/sesión/CSRF.** Esto se añade *después* de validar la
   frontera de privilegios, no antes.

## Próximos pasos (orden)

1. Endurecer límites/rutas/secretos/transiciones (hecho en v2).
2. Probar la frontera real (usuario web vs. ajeno vs. executor root) en la RPi.
3. Sustituir el stub por `install.sh --only plex` en un entorno recuperable.
4. Implementar autenticación, sesión y CSRF.
