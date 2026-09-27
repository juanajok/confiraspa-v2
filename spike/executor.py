#!/usr/bin/env python3
"""Spike: executor privilegiado de Confiraspa (v2 — endurecido).

- Socket Unix con protocolo JSON de una línea; límites de tamaño y tiempo.
- Allowlist con esquema estricto y argumentos de lista (sin shell, sin interpolar).
- Captura de salida ACOTADA desde el origen + timeout de ejecución.
- Redacción de secretos + límite de tamaño.
- Jobs persistentes (SQLite): pending→running→success|failed, con semántica de
  recuperación (excepción → failed; 'running'/'pending' obsoletos → failed).
- Concurrencia: máximo 1 operación a la vez.
"""
import json
import os
import re
import socket
import socketserver
import stat
import subprocess
import sys
import threading

import jobs

SOCKET_PATH = os.environ.get("CONFIRASPA_EXECUTOR_SOCKET", "/run/confiraspa/executor.sock")
MAX_OUTPUT = 64 * 1024        # bytes de salida conservados
MAX_LINE = 256 * 1024         # bytes de petición por socket
CONN_TIMEOUT = int(os.environ.get("CONFIRASPA_CONN_TIMEOUT", "30"))  # segundos para leer una petición
EXEC_TIMEOUT = int(os.environ.get("CONFIRASPA_EXEC_TIMEOUT", "30"))

CATALOG = {"plex"}

SECRET_PATTERNS = [
    re.compile(rb"(?i)(password|passwd|pass|token|secret|api[_-]?key|authorization)\s*[=:]\s*([^\s\"'`,]+)"),
    re.compile(rb"(https?://[^\s]+:[^\s@]+@)"),  # credenciales en URL
]


def redact(data: bytes) -> bytes:
    for p in SECRET_PATTERNS:
        data = p.sub(rb"\1***REDACTED***", data)
    return data


def _run_bounded(cmd, timeout, max_output):
    """Ejecuta `cmd` (lista, sin shell) con salida acotada y timeout.

    La salida se drena en un hilo y se conservan como máximo `max_output` bytes;
    no se acumula en memoria de forma ilimitada.
    """
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True
        )
    except Exception as e:  # binario inexistente, etc.
        return 1, f"[ejecución fallida: {e}]\n".encode()

    buf = bytearray()
    truncated = False

    def drain():
        nonlocal truncated
        try:
            while True:
                chunk = proc.stdout.read(4096)
                if not chunk:
                    break
                if len(buf) < max_output:
                    buf.extend(chunk[: max_output - len(buf)])
                else:
                    truncated = True
        except Exception:
            pass

    t = threading.Thread(target=drain, daemon=True)
    t.start()
    try:
        code = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), 9)
        except Exception:
            proc.kill()
        proc.wait()
        t.join(timeout=2)
        return 124, bytes(buf) + b"\n...[timeout]\n"
    t.join(timeout=2)
    if truncated:
        buf += b"\n...[truncado]\n"
    return code, bytes(buf)


def op_echo(params):
    return _run_bounded(["echo", params["message"]], EXEC_TIMEOUT, MAX_OUTPUT)


def op_install(params):
    app = params["app_id"]
    # Argument list, sin shell: el app_id viaja como argumento separado, nunca
    # interpolado en un string. En producción: [SCRIPT, "--only", app].
    return _run_bounded(
        ["python3", "-c",
         "import sys,time; time.sleep(float(sys.argv[2])); print('instalado '+sys.argv[1], flush=True)",
         app, os.environ.get("CONFIRASPA_INSTALL_SLEEP", "2")],
        EXEC_TIMEOUT, MAX_OUTPUT,
    )


def op_fail(_):
    return _run_bounded(["/bin/false"], EXEC_TIMEOUT, MAX_OUTPUT)  # test: fallo real


def op_slow(_):
    return _run_bounded(["python3", "-c", "import time; time.sleep(60)"], EXEC_TIMEOUT, MAX_OUTPUT)


def op_spew(_):
    # Genera salida masiva para probar la captura acotada desde el origen.
    return _run_bounded(["python3", "-c", "print('z'*200000)"], EXEC_TIMEOUT, MAX_OUTPUT)


OPERATIONS = {
    "echo":        {"params": {"message": str}, "required": ["message"], "run": op_echo},
    "app.install": {"params": {"app_id": str}, "required": ["app_id"],
                    "allowlist": {"app_id": CATALOG}, "run": op_install},
    "fail":        {"params": {}, "required": [], "run": op_fail},   # solo para tests
    "slow":        {"params": {}, "required": [], "run": op_slow},   # solo para tests
    "spew":        {"params": {}, "required": [], "run": op_spew},   # solo para tests
}

run_lock = threading.Lock()


def validate(operation, params):
    if operation not in OPERATIONS:
        return None, f"operación desconocida: {operation}"
    spec = OPERATIONS[operation]
    if not isinstance(params, dict):
        return None, "params debe ser un objeto JSON"
    extra = set(params) - set(spec["params"])
    if extra:
        return None, f"parámetros no permitidos: {sorted(extra)}"
    missing = [k for k in spec["required"] if k not in params]
    if missing:
        return None, f"faltan parámetros: {missing}"
    out = {}
    for k, v in params.items():
        typ = spec["params"][k]
        if not isinstance(v, typ):
            return None, f"parámetro '{k}' debe ser {typ.__name__}"
        al = spec.get("allowlist", {}).get(k)
        if al is not None and v not in al:
            return None, f"valor no permitido para '{k}': {v!r}"
        out[k] = v
    return out, None


def handle(job_id, operation, params):
    p, err = validate(operation, params)
    if err:
        jobs.update_job(job_id, status="failed", exit_code=2, output=err)
        return {"ok": False, "error": err}

    if not run_lock.acquire(blocking=False):
        jobs.update_job(job_id, status="failed", exit_code=3,
                        output="límite de concurrencia: ya hay una operación en curso")
        return {"ok": False, "error": "busy"}

    try:
        jobs.update_job(job_id, status="running")
        code, out = OPERATIONS[operation]["run"](p)
        out = redact(out)[:MAX_OUTPUT + 512]  # redactar y asegurar límite final
        status = "success" if code == 0 else "failed"
        jobs.update_job(job_id, status=status, exit_code=code, output=out.decode(errors="replace"))
        return {"ok": True, "status": status, "exit_code": code}
    except Exception as e:  # excepción durante la operación → failed, no running
        jobs.update_job(job_id, status="failed", exit_code=1, output=f"excepción: {e}")
        return {"ok": False, "error": str(e)}
    finally:
        run_lock.release()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(CONN_TIMEOUT)
        data = b""
        try:
            while not data.endswith(b"\n"):
                chunk = self.request.recv(4096)
                if not chunk:
                    break
                data += chunk
                if len(data) > MAX_LINE:
                    self._reply({"ok": False, "error": "petición demasiado grande"})
                    return
        except socket.timeout:
            return  # cliente que nunca termina la línea: se cierra sin responder
        try:
            req = json.loads(data)
            resp = handle(req["job_id"], req["operation"], req.get("params", {}))
        except Exception as e:
            resp = {"ok": False, "error": f"petición inválida: {e}"}
        self._reply(resp)

    def _reply(self, resp):
        try:
            self.request.sendall((json.dumps(resp) + "\n").encode())
        except Exception:
            pass


def main():
    # No borrar rutas arbitrarias: solo un socket obsoleto Nuestro.
    if os.path.exists(SOCKET_PATH):
        if stat.S_ISSOCK(os.stat(SOCKET_PATH).st_mode):
            os.unlink(SOCKET_PATH)
        else:
            print(f"rehúso: {SOCKET_PATH} existe y no es un socket", file=sys.stderr)
            sys.exit(1)
    jobs.mark_stale_jobs_failed()
    srv = socketserver.ThreadingUnixStreamServer(SOCKET_PATH, Handler)
    os.chmod(SOCKET_PATH, 0o660)
    print(f"executor escuchando en {SOCKET_PATH}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
