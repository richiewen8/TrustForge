#!/bin/sh
# Lab drill hooks: the "always" marker fails every health call (RollbackFailed drill);
# the one-shot marker fails exactly once so verify fails but the rollback health passes.
if [ -f /tmp/trustforge-health-fail-always ]; then
    exit 1
fi
if [ -f /tmp/trustforge-health-fail ]; then
    rm -f /tmp/trustforge-health-fail
    exit 1
fi
exec /usr/local/libexec/trustforge-demo/health.sh "$1"