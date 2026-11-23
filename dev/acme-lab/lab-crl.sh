#!/usr/bin/env bash
# Shared CRL helpers for drill-revocation.sh and verify.sh. Source it after cd-ing into this directory.
# The published endpoint is loopback while the certificate names the container host, so the connection
# goes to 127.0.0.1 but is verified against that host with the lab root: no verification is relaxed.

STEP_CA="${STEP_CA:-https://127.0.0.1:${LAB_STEP_CA_PORT:-9000}}"
CRL_DIR="${CRL_DIR:-secrets/probe}"
CRL_ROOT_CA="${CRL_ROOT_CA:-secrets/root_ca.crt}"

# Downloads the CA CRL and prints the openssl decoding, which lists every revoked serial and reason.
crl_text() {
    mkdir -p "$CRL_DIR"
    python - "$STEP_CA" "$CRL_DIR/crl.der" "$CRL_ROOT_CA" <<'PY'
import socket, ssl, sys, urllib.parse
url = urllib.parse.urlparse(sys.argv[1] + "/1.0/crl")
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.load_verify_locations(sys.argv[3])
context.check_hostname = True
context.verify_mode = ssl.CERT_REQUIRED
stream = context.wrap_socket(
    socket.create_connection((url.hostname, url.port or 443), timeout=10), server_hostname="step-ca")
stream.sendall(b"GET /1.0/crl HTTP/1.1\r\nHost: step-ca\r\nConnection: close\r\n\r\n")
buffer = b""
while True:
    chunk = stream.recv(65536)
    if not chunk:
        break
    buffer += chunk
stream.close()
head, _, body = buffer.partition(b"\r\n\r\n")
status = head.split(b"\r\n", 1)[0]
if not status.endswith(b"200 OK"):
    raise SystemExit("CRL endpoint returned " + status.decode(errors="replace"))
open(sys.argv[2], "wb").write(body)
PY
    openssl crl -in "$CRL_DIR/crl.der" -inform DER -noout -text
}

# Succeeds when the serial is listed in the CRL.
crl_lists() {
    crl_serials | grep -qxF "$(printf '%s' "$1" | tr 'a-f' 'A-F')"
}

crl_serials() {
    crl_text | python -c 'import re,sys
text = sys.stdin.read().split("Revoked Certificates:")[-1]
print("\n".join(s.upper() for s in re.findall(r"Serial Number:\s*([0-9A-Fa-f]+)", text)))'
}

# Prints the reason of one revoked serial, "none" when the entry carries no reason extension,
# or "MISSING" when the serial is not revoked.
crl_entry() {
    crl_text | python -c 'import re,sys
text = sys.stdin.read().split("Revoked Certificates:")[-1]
for serial, tail in re.findall(r"Serial Number:\s*([0-9A-Fa-f]+)(.*?)(?=Serial Number:|\Z)", text, re.S):
    if serial.upper() != sys.argv[1].upper():
        continue
    reason = re.search(r"CRL Reason Code:\s*\n\s*(.+)", tail)
    print(reason.group(1).strip() if reason else "none")
    sys.exit(0)
print("MISSING")' "$1"
}
