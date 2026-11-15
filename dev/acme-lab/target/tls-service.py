#!/usr/bin/python3
"""Demo TLS endpoint presenting the currently active TrustForge release."""
import socket
import ssl
from pathlib import Path

CURRENT = Path("/etc/trustforge-demo/current")

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(CURRENT / "chain.pem", CURRENT / "private-key.pem")

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", 8443))
    sock.listen(16)
    with context.wrap_socket(sock, server_side=True) as tls:
        while True:
            try:
                conn, _ = tls.accept()
            except ssl.SSLError:
                continue
            with conn:
                try:
                    conn.sendall(b"TrustForge demo TLS service\n")
                except OSError:
                    pass