#!/bin/sh
# First-install validation runs before any certificate exists; absence is healthy.
if [ ! -L /etc/trustforge-demo/current ]; then
    exit 0
fi
expected=$(openssl x509 -in /etc/trustforge-demo/current/certificate.pem -outform DER | sha256sum | cut -d' ' -f1)
attempt=0
while [ "$attempt" -lt 10 ]; do
    actual=$(echo | openssl s_client -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ -n "$actual" ] && [ "$expected" = "$actual" ]; then
        exit 0
    fi
    sleep 1
    attempt=$((attempt + 1))
done
exit 1