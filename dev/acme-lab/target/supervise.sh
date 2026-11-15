#!/bin/sh
# Restart the demo TLS service whenever it exits so reload.sh can apply a new release.
while true; do
    if [ -L /etc/trustforge-demo/current ]; then
        python3 /usr/local/libexec/trustforge-demo/tls-service.py
    fi
    sleep 1
done