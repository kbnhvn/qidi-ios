#!/usr/bin/env python3
"""Imitation minimale de Moonraker pour le test de bout en bout (scripts/e2e-linux.sh).

Endpoints utilisés par l'app : POST /server/files/upload (multipart, root=gcodes),
POST /printer/print/start?filename=…, GET /printer/objects/query?….
Écrit ce qu'il a reçu dans <journal>.json pour que le test puisse le vérifier.

    mock_moonraker.py <port|0> <journal.json> <fichier-port>
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, LOG, PORT_FILE = int(sys.argv[1]), sys.argv[2], sys.argv[3]
state = {"uploads": [], "started": [], "queries": 0, "api_keys": []}


def save():
    with open(LOG, "w") as f:
        json.dump(state, f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.headers.get("X-Api-Key"):
            state["api_keys"].append(self.headers["X-Api-Key"])
        if self.path.startswith("/server/files/upload"):
            boundary = re.search(r"boundary=(.+)", self.headers.get("Content-Type", "")).group(1).encode()
            fields, filename, payload = {}, None, b""
            for part in body.split(b"--" + boundary):
                if b"Content-Disposition" not in part:
                    continue
                head, _, data = part.partition(b"\r\n\r\n")
                data = data[:-2] if data.endswith(b"\r\n") else data
                name = re.search(rb'name="([^"]*)"', head).group(1).decode()
                if b"filename=" in head:
                    filename = re.search(rb'filename="([^"]*)"', head).group(1).decode()
                    payload = data
                else:
                    fields[name] = data.decode()
            state["uploads"].append({"filename": filename, "size": len(payload), "root": fields.get("root"),
                                     "head": payload[:12].decode("latin-1")})
            save()
            self._json(201, {"result": {"item": {"path": filename}}})
        elif self.path.startswith("/printer/print/start"):
            state["started"].append(self.path.split("filename=", 1)[-1])
            save()
            self._json(200, {"result": "ok"})
        else:
            self._json(404, {"error": "inconnu"})

    def do_GET(self):
        if self.path.startswith("/printer/objects/query"):
            state["queries"] += 1
            save()
            started = bool(state["started"])
            self._json(200, {"result": {"status": {
                "print_stats": {"state": "printing" if started else "standby",
                                "filename": state["started"][-1] if started else ""},
                "display_status": {"progress": 0.5 if started else 0.0},
                "extruder": {"temperature": 219.6, "target": 220.0},
                "heater_bed": {"temperature": 59.8, "target": 60.0}}}})
        else:
            self._json(404, {"error": "inconnu"})


server = HTTPServer(("127.0.0.1", PORT), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_address[1]))
save()
server.serve_forever()
