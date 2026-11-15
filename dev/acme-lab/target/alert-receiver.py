#!/usr/bin/python3
"""Lab-only webhook receiver appending delivered TrustForge alerts as JSON lines."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

LOG = Path("/var/lib/trustforge-demo/alerts.jsonl")


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(min(length, 65536))
        try:
            alert = json.loads(raw)
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(alert, separators=(",", ":")) + "\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", 8444), Handler).serve_forever()