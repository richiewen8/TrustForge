#!/bin/sh
set -e
install -d -o trustforge-deployer -g trustforge-deployer -m 0700 /home/trustforge-deployer/.ssh
if [ -f /run/trustforge/authorized_keys ]; then
    install -o trustforge-deployer -g trustforge-deployer -m 0600 /run/trustforge/authorized_keys /home/trustforge-deployer/.ssh/authorized_keys
fi
/usr/sbin/sshd
python3 /usr/local/libexec/trustforge-demo/alert-receiver.py &
exec /usr/local/libexec/trustforge-demo/supervise.sh