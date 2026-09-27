#!/usr/bin/env python3
"""Spike: executor privilegiado de Confiraspa.

- Socket Unix (permisos 0660) con protocolo JSON de una línea por petición.
- Allowlist de operaciones con esquema estricto de parámetros.
- Ejecuta una función permitida, captura salida, redacta secretos, trunca.
- Jobs persistentes en SQLite (pending→running→success/failed).
- Concurrencia: máximo 1 operación a la vez (lock).
"""
import json
import os
import re
import socketserver
import subprocess
import threading

import jobs

SOCKET_PATH = os.environ.get("CONFIRASPA_EXECUTOR_SOCKET", "/tmp/confiraspa-executor.sock")
MAX_OUTPUT = 64 * 1024  # 64 KB

# Catálogo cerrado del spike (un solo ID). En producción, el catálogo real.
CATALOG = {"plex"}

# Patrones a redactar: nunca devolver secretos al cliente.
SECRET_PATTERNS = [
    re.compile(rb"(?i)(password|passwd|pass|token|secret|api[_-]?key|authorization)\s*[=:]\s*([^\s\"'`,]+)"),
]


def redact(data: bytes) -> bytes:
    for p in SECRET_PATTERNS:
        data = p.sub(rb"\1=***REDACTED***", data)
    return data


def truncate(data: bytes) -> bytes:
    if len(data) > MAX_OUTPUT:
        return data[:MAX_OUTPUT] + b"\n...[truncado]"
    return data


def _run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.returncode, p.stdout


def op_echo(params):
    return _run(["echo", params["message"]])


def op_install(params):
    app = params["app_id"]
    # STUB del spike. En producción: ["bash", "install.sh", "--only", app].
    return _run(["bash", "-c", f"echo 'instalando {app}...'; sleep 2; echo 'instalado {app}'"])


OPERATIONS = {
    "echo": {
        "params": {"message": str},
        "required": ["message"],
        "run": op_echo,
    },
    "app.install": {
        "params": {"app_id": str},
        "required": ["app_id"],
        "allowlist": {"app_id": CATALOG},
        "run": op_install,
    },
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
        out = truncate(redact(out))
        status = "success" if code == 0 else "failed"
        jobs.update_job(job_id, status=status, exit_code=code,
                        output=out.decode(errors="replace"))
        return {"ok": True, "status": status, "exit_code": code}
    finally:
        run_lock.release()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        data = b""
        while not data.endswith(b"\n"):
            chunk = self.request.recv(4096)
            if not chunk:
                break
            data += chunk
        try:
            req = json.loads(data)
            resp = handle(req["job_id"], req["operation"], req.get("params", {}))
        except Exception as e:  # petición malformada
            resp = {"ok": False, "error": f"petición inválida: {e}"}
        self.request.sendall((json.dumps(resp) + "\n").encode())


def main():
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    jobs.mark_stale_running_failed()
    srv = socketserver.ThreadingUnixStreamServer(SOCKET_PATH, Handler)
    os.chmod(SOCKET_PATH, 0o660)  # grupo confiraspa (spike: se deja 0660)
    print(f"executor escuchando en {SOCKET_PATH}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
