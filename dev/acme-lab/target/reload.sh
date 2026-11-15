#!/bin/sh
# The supervisor restarts the TLS service against the new current symlink target.
pkill -f tls-service.py || true