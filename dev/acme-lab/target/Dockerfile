FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server python3 openssl sudo curl procps \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && ssh-keygen -A \
    && useradd -m -s /bin/bash trustforge-deployer \
    && echo 'trustforge-deployer ALL=(root) NOPASSWD: /usr/local/sbin/trustforge-certctl' > /etc/sudoers.d/trustforge \
    && chmod 0440 /etc/sudoers.d/trustforge \
    && install -d -o root -g root -m 0755 /etc/trustforge/services /var/lib/trustforge /usr/local/libexec/trustforge-demo \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

COPY remote-helper/trustforge-certctl /usr/local/sbin/trustforge-certctl
COPY dev/acme-lab/target/actions.json /etc/trustforge/actions.json
COPY dev/acme-lab/target/tls-service.py dev/acme-lab/target/supervise.sh dev/acme-lab/target/reload.sh dev/acme-lab/target/health.sh dev/acme-lab/target/health-conditional.sh dev/acme-lab/target/alert-receiver.py /usr/local/libexec/trustforge-demo/
COPY dev/acme-lab/target/entrypoint.sh /usr/local/sbin/lab-entrypoint.sh

RUN chown root:root /usr/local/sbin/trustforge-certctl /etc/trustforge/actions.json /usr/local/sbin/lab-entrypoint.sh \
    && chmod 0750 /usr/local/sbin/trustforge-certctl \
    && chmod 0600 /etc/trustforge/actions.json \
    && chmod 0755 /usr/local/sbin/lab-entrypoint.sh /usr/local/libexec/trustforge-demo/supervise.sh /usr/local/libexec/trustforge-demo/reload.sh /usr/local/libexec/trustforge-demo/health.sh /usr/local/libexec/trustforge-demo/health-conditional.sh /usr/local/libexec/trustforge-demo/tls-service.py /usr/local/libexec/trustforge-demo/alert-receiver.py \
    && chown -R root:root /usr/local/libexec/trustforge-demo

EXPOSE 22 8443
ENTRYPOINT ["/usr/local/sbin/lab-entrypoint.sh"]