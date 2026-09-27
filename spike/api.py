#!/usr/bin/env python3
"""Spike: API web mínima (sin root) que habla con el executor vía socket Unix.

Endpoints del spike:
  GET  /api/v1/apps                       → catálogo
  POST /api/v1/apps/{id}/install          → crea job y lo envía al executor
  POST /api/v1/echo                       → operación de prueba (body JSON = params)
  POST /api/v1/fail, /api/v1/slow         → ops de prueba (fallo / timeout)
  GET  /api/v1/jobs/{id}                  → estado del job (params resumidos, sin secretos)
"""
import json
import os
import socket
import threading
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

import jobs

EXECUTOR_SOCKET = os.environ.get("CONFIRASPA_EXECUTOR_SOCKET", "/run/confiraspa/executor.sock")
MAX_BODY = 64 * 1024  # límite de body HTTP
CATALOG = {"plex"}


def send_to_executor(job_id, operation, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(60)
    s.connect(EXECUTOR_SOCKET)
    s.sendall((json.dumps({"job_id": job_id, "operation": operation, "params": params}) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data)


def dispatch(job_id, operation, params):
    def _go():
        try:
            send_to_executor(job_id, operation, params)
        except Exception as e:
            jobs.update_job(job_id, status="failed", exit_code=1, output=f"no se pudo contactar al executor: {e}")
    threading.Thread(target=_go, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n > MAX_BODY:
            return None  # demasiado grande
        if n == 0:
            return {}
        try:
            return json.loads(self.rfile.read(n))
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        if self.path == "/api/v1/apps":
            return self._send({"apps": sorted(CATALOG)})
        if self.path.startswith("/api/v1/jobs/"):
            job = jobs.get_job(self.path.rsplit("/", 1)[-1])
            if not job:
                return self._send({"error": "job no encontrado"}, 404)
            return self._send(job)
        return self._send({"error": "no encontrado"}, 404)

    def do_POST(self):
        parts = self.path.split("/")
        # POST /api/v1/apps/{id}/install
        if len(parts) == 6 and parts[1:4] == ["api", "v1", "apps"] and parts[5] == "install":
            app_id = parts[4]
            if app_id not in CATALOG:
                return self._send({"error": f"app desconocida: {app_id}"}, 404)
            params = {"app_id": app_id}
            return self._start_job("app.install", params)

        # POST /api/v1/{op} para echo/fail/slow
        op = parts[-1]
        if self.path in ("/api/v1/echo", "/api/v1/fail", "/api/v1/slow", "/api/v1/spew"):
            params = self._read_body()
            if params is None:
                return self._send({"error": "body demasiado grande"}, 413)
            return self._start_job(op, params)

        return self._send({"error": "no encontrado"}, 404)

    def _start_job(self, operation, params):
        job_id = "j_" + uuid.uuid4().hex[:12]
        jobs.create_job(job_id, operation, jobs.summarize(operation, params))
        dispatch(job_id, operation, params)
        return self._send({"job_id": job_id}, 202)

    def log_message(self, *args):
        pass


def main():
    port = int(os.environ.get("CONFIRASPA_API_PORT", "8080"))
    srv = HTTPServer(("127.0.0.1", port), Handler)
    print(f"api escuchando en 127.0.0.1:{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
