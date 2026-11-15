# Linux SSH deployment helper

TrustForge connects with SSH.NET, verifies the configured OpenSSH `SHA256:` host fingerprint, and runs only the fixed command `sudo -n /usr/local/sbin/trustforge-certctl`. A JSON request is sent over stdin; no request field is interpolated into a shell command. The target generates and retains the service private key. The API receives only the CSR and public certificate chain.

## Install on each Linux target

Install Python 3 and OpenSSL, then install the helper as a root-owned executable:

```sh
sudo install -o root -g root -m 0750 trustforge-certctl /usr/local/sbin/trustforge-certctl
sudo install -d -o root -g root -m 0700 /etc/trustforge/services
sudo install -d -o root -g root -m 0700 /var/lib/trustforge
```

Create `/etc/trustforge/actions.json` as root, mode `0600`. It maps registered action IDs to argument arrays, never shell strings. Example:

```json
{
  "nginx-reload": ["/usr/bin/systemctl", "reload", "nginx"],
  "nginx-health": ["/usr/local/libexec/check-nginx-tls", "{service_id}"]
}
```

The referenced executables and their configuration must be root-owned and non-writable by the SSH account. Add one root-owned mode `0600` service JSON file named `/etc/trustforge/services/<service-guid-without-dashes>.json`:

```json
{
  "certificatePath": "/etc/nginx/trustforge/current/certificate.pem",
  "chainPath": "/etc/nginx/trustforge/current/chain.pem",
  "privateKeyPath": "/etc/nginx/trustforge/current/private-key.pem",
  "fileOwner": "root",
  "fileGroup": "nginx",
  "fileMode": "0600",
  "remoteHelperId": "trustforge-certctl-v1",
  "reloadActionId": "nginx-reload",
  "healthCheckId": "nginx-health"
}
```

The three paths must share the same `current` parent. Prepare the parent as an administrator-controlled symlink, initially pointing to the current certificate release (or leave it absent for a first install). The helper stages each release in `/var/lib/trustforge/releases`, atomically swaps the `current` symlink, remembers its previous target, reloads the registered action, verifies the active certificate fingerprint, file ownership/permissions and health action, and can restore the prior symlink and reload the previous release.

Supported operations (JSON `operation` field): `validate`, `generate-csr`, `stage`, `activate`, `verify`, `rollback`, `prune`. `verify` re-checks that the active certificate and chain are mode `0644` and the private key matches the registered `fileMode`, all owned by the registered `fileOwner`:`fileGroup`, before running the health action. `prune` enforces the retention policy: with `retainedReleases` (1–50) it deletes old release directories and their job key directories under the service's own roots only, never the active `current` target, never the recorded rollback slot, and always the newest `retainedReleases` releases. The API calls `prune` after a successful verification; a prune failure is logged and does not roll back the deployment.

Create a dedicated SSH account and restrict sudo to this executable:

```sudoers
trustforge-deployer ALL=(root) NOPASSWD: /usr/local/sbin/trustforge-certctl
```

The SSH secret referenced by the managed service is JSON with `username`, `privateKeyPem`, and optional `passphrase`; configure it through the existing `secret://env/NAME` or absolute `secret://file/...` resolver. Keep the secret outside PostgreSQL and source control. Store the host fingerprint in OpenSSH format (`SHA256:` plus 43 base64 characters).

The helper trusts only root-managed service registrations and action maps. Do not allow the SSH account to write the helper, registrations, action map, executable targets, or any parent directory. Keep `/var/lib/trustforge` on persistent local storage so a retry can recover the same CSR and previous activation record.
