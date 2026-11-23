# TrustForge operations manual

This manual is for operators who run TrustForge in production: where durable state lives,
how to back it up and restore it, how to rotate keys, how to upgrade the schema, and how to
monitor the system. The backup/restore procedure here is rehearsed end to end by the
disposable lab drills `dev/acme-lab/drill-backup.sh` and `dev/acme-lab/drill-restore.sh`.

TrustForge is one application process (API + embedded Technitium DNS + certificate worker)
with PostgreSQL as its persistence dependency and an external Smallstep `step-ca` as the ACME
issuer. It runs either as a container pair under Compose ([DEPLOYMENT.md](DEPLOYMENT.md)) or as
a systemd service on a physical host ([BAREMETAL.md](BAREMETAL.md)); the schema, the pipeline and
most of this manual are identical. Where a procedure differs, both forms are shown, marked
**Compose** and **bare metal**. See [CERTIFICATE-PIPELINE.md](CERTIFICATE-PIPELINE.md) for the
durable stage protocol.

## 1. Where state lives

| State | Location | Secret? | Backup method |
| --- | --- | --- | --- |
| Jobs, transitions, services, deployment versions, alerts | PostgreSQL (`certificate_jobs`, `certificate_job_transitions`, `managed_services`, `deployment_versions`, `certificate_alerts`) | No private keys; secret **references** only | `pg_dump -Fc` |
| CA root/intermediate keys, ACME account/order DB, provisioner config | step-ca data volume (`/home/step`) | **Yes — CA keys** | volume tar (CA stopped) |
| Issued public certificate bundles | `trustforge-certificate-artifacts` volume | No (public material) | volume tar |
| DNS zone files, users, API tokens | `trustforge-dns-config` volume (embedded Technitium) | API token hashes | volume tar |
| Target service/action registrations, releases, **per-job private keys**, served `current` symlink | each Linux target's filesystem (`/etc/trustforge`, `/var/lib/trustforge`, `/etc/trustforge-demo`) | **Yes — target private keys** | target filesystem tar |
| ACME account key, DNS API token, SSH deployer credential, CA root PEM | secret store referenced by `secret://…` (lab: `dev/acme-lab/secrets/`) | **Yes** | secret-store backup |

On a bare-metal host the same state lives on directories instead of volumes
(`deploy/bare-metal/install.sh` fixes these paths; the first three are in the unit's
`ReadWritePaths`):

| State | Bare-metal location |
| --- | --- |
| Jobs, services, versions, alerts | the PGDG cluster `postgresql@17-main` (`/var/lib/postgresql/17/main`) |
| Issued public certificate bundles | `/var/lib/trustforge/artifacts` |
| DNS zone files, users, API tokens | `/etc/trustforge/dns` (**frozen at first boot**, see BAREMETAL.md) |
| ACME account key, DNS API token, SSH deployer credentials, CA root PEM | `/etc/trustforge/secrets` (`0750 root:trustforge`, files `0640`, read-only to the service) |
| Runtime configuration | `/etc/trustforge/trustforge.env` (`0600`, root) |

`/run/trustforge/secrets` is the **container** path only. On a host it is tmpfs and would vanish at
reboot, so secret references authored for a bare-metal install must name `/etc/trustforge/secrets` —
and because those references are stored in the database (`sshCredentialRef`), that choice is one-way.

Two invariants shape every procedure below:

- **Private keys never enter PostgreSQL, logs or checkpoints.** They are generated on the
  target and stay there; the CA keys stay in the step-ca volume. A PostgreSQL dump alone is
  therefore *not* a full backup — you must also capture the CA volume and the targets.
- **The database stores only secret references** (`secret://env/NAME`,
  `secret://file//<abs>` — the double slash is required so the remainder parses as an absolute
  path; see `TrustForge.Api/EnvironmentSecretResolver.cs`).
  Restoring the database does not restore the secrets themselves; the secret store must be
  restored independently and reachable at the same references.

## 2. Certificate Authority operations

### 2.1 Known step-ca defect (order index corruption)

step-ca's nosql ACME backend (v0.30.2, still unfixed upstream at the time of writing)
corrupts the account order index once every order of an account has completed: listing
orders stores empty bytes, and every later new-order/list for that account fails with HTTP
500 (`error unmarshaling orderIDs ... unexpected end of JSON input`, or `changed since last
read`). TrustForge's order reconciliation lists orders, so it triggers this on unpatched
servers. The lab builds step-ca with a two-line fix (`dev/acme-lab/step-ca/Dockerfile`).
**Production step-ca deployments need the same patch or a fixed release.** If new-order
suddenly returns 500 after a period of success, suspect an unpatched/stale step-ca image
before touching TrustForge. The patch is specific to the nosql backend; re-verify it if you
move step-ca to a SQL backend (see [HSM-KMS-HA-EVALUATION.md](HSM-KMS-HA-EVALUATION.md)).

### 2.2 Backing up the CA

Stop step-ca first so the badger DB is consistent, then archive its data:

**Compose:**

```sh
docker compose stop step-ca
docker run --rm -v <project>_stepca-data:/data:ro --entrypoint sh <helper-image> \
    -c 'tar -czf - -C /data .' > stepca.tar.gz
docker compose up -d step-ca
```

**Bare metal** (step-ca installed as a host service, the usual shape next to a
`deploy/bare-metal` TrustForge): stop the unit and tar its directory, no helper container needed:

```sh
systemctl stop step-ca
tar -czf - -C /home/step . > stepca.tar.gz
systemctl start step-ca
```

`stepca.tar.gz` contains the root and intermediate **private keys** — store it encrypted,
access-controlled, and off-host. The lab uses the target image as the helper with
`--entrypoint sh` (without that override the image ENTRYPOINT starts lab services and
blocks).

### 2.3 Restoring the CA — restore BEFORE first start

> **Critical:** the step-ca image runs `DOCKER_STEPCA_INIT_*` initialization on an *empty*
> data volume. If you start step-ca before restoring its volume, it generates a **brand-new
> CA** and the restored root no longer matches anything. Always populate the volume first.

```sh
docker compose down -v                 # removes the empty volume
docker run --rm -i -v <project>_stepca-data:/data --entrypoint sh <helper-image> \
    -c 'tar -xzf - -C /data' < stepca.tar.gz
docker compose up -d step-ca           # sees existing state, does NOT re-initialize
```

**Bare metal:** the same ordering applies — the directory must be non-empty before step-ca first
starts, or its own init will mint a different CA:

```sh
systemctl stop step-ca
install -d -o step -g step /home/step && tar -xzf stepca.tar.gz -C /home/step
systemctl start step-ca
```

After restore, the CA root PEM distributed to TrustForge (`SmallstepAcme:RootCertificatePath`)
and to every target must be the **restored** root, not a freshly generated one. On a bare-metal
host that file lives under `/etc/trustforge/secrets` and `RootCertificatePath` must name it there.

### 2.4 Root / intermediate rotation vs ACME account-key rotation

These are different operations:

- **CA root/intermediate rotation** is a step-ca operation (`step ca root`, renewing the
  intermediate, or standing up a new root and cross-signing). It changes the trust anchor:
  every relying party (TrustForge's `RootCertificatePath`, every target's trust store) must
  receive the new root, and already-issued certificates remain valid only until they expire
  or are re-issued under the new intermediate. Plan it as a scheduled re-issuance window
  driven by the renewal scheduler, not an emergency.
- **ACME account-key rotation** changes only the key TrustForge uses to authenticate to the
  CA. Generate a new EC P-256 PKCS#8 key, update the secret behind
  `SmallstepAcme:AccountKeySecretRef`, and restart the worker. The issuer registers the new
  key as a new ACME account; existing orders belong to the old account and are not reused.
  This does **not** change the trust anchor and does not require touching targets.

### 2.5 Renewal and expiry operations

- Automatic renewal is per-service (`renewalEnabled`, `renewalLeadTime`). The
  `RenewalSchedulerWorker` scans every `CertificateJobs:Renewal:ScanInterval` and creates at
  most one renewal job per service per `MinimumRenewalInterval`, keyed by certificate
  fingerprint (`renewal-{fingerprint}`). Keep `renewalLeadTime` **below** the issued
  certificate lifetime: a lead time ≥ lifetime leaves the service permanently inside its own
  renewal window, so the scheduler renews continuously — one issuance every
  `MinimumRenewalInterval` — instead of resting until the next real expiry. The interval
  throttles that cascade; it does not prevent it. Sustained `renewal-scheduler` jobs for a
  service that is not approaching expiry are the symptom; check its lead time against the
  certificate lifetime.
- Expiry reminders are independent of renewal: the `ExpiryReminderWorker` scans every
  `CertificateJobs:Expiry:ScanInterval` and raises a `CertificateExpiring` (Warning) alert
  for every enabled service whose active certificate is inside
  `CertificateJobs:Expiry:ReminderWindow`, deduped per service+fingerprint
  (`expiring:{serviceId}:{fingerprint}`). Reminders fire even for renewal-enabled services
  as a safety net. Tune the window so operators have lead time to act if renewal fails.
- Durations use the .NET constant format `d.hh:mm:ss`. **`25:00:00` parses as 25 days, not
  25 hours** — use `1.01:00:00` for 25 hours.

### 2.6 Revocation and CRL distribution

Enabling CRL publication on step-ca (the OSS CA ships with it **disabled**, which makes
revocations invisible to relying parties) means adding a `crl` block to `ca.json` and
restarting the CA:

```json
{ "crl": { "enabled": true, "generateOnRevoke": true,
           "renewPeriod": "600s", "cacheDuration": "3600s",
           "idpURL": "https://step-ca:9000/1.0/crl" } }
```

The list is then served by `GET /1.0/crl` on the CA port, and already-stored revocations
appear in it after the next generation. Measured with that block on step-ca 0.30.2: the
`nextUpdate` of the published CRL is `lastUpdate + cacheDuration` (3600 s), and a serial revoked
through the API was listed within seconds, because `generateOnRevoke` triggers the regeneration —
without it, budget up to `renewPeriod`/`cacheDuration` before the serial is visible, and a
publication timeout is then a timing question rather than a lost revocation. Two CA limits to plan
around: issued leaves carry **no** CRL Distribution Points extension even when `idpURL` is set, so
relying parties must be pointed at the CRL URL out of band; and OSS step-ca has no OCSP responder.
TrustForge's own deployment verification uses `X509RevocationMode.NoCheck` — it proves the chain
builds against the configured root and matches the deployed fingerprint, while revocation status is
asserted against the CA's CRL.

To revoke:

```sh
curl -X POST "$API/api/v1/services/$SERVICE_ID/revocations" \
  -H "Authorization: Bearer $PLATFORM_ADMIN_TOKEN" \
  -H "Idempotency-Key: incident-2026-11-23-01" \
  -H "Content-Type: application/json" \
  -d '{"reason":"KeyCompromise"}'
```

- Requires the `PlatformAdmin` role: revocation is irreversible, so it is deliberately
  narrower than issuance (`CertificateOperator`).
- The revoked certificate is the one behind the service's `Active` deployment version, read
  back from the stored artifact; the caller cannot name a serial. Expected outcomes are
  `200 revoked`/`200 replayed`, `202 pending` (CA unreachable — the durable retry worker
  finishes it), and `409 service_job_active` / `409 no_active_certificate`.
- Re-sending with a different idempotency key replays the same record; the CA is asked at
  most once per serial, and an `alreadyRevoked` answer is treated as success.
- **Revoking does not touch the deployment.** The target keeps serving the revoked leaf
  until the next issuance replaces it, so for a compromised key the sequence is revoke →
  immediately issue (which also regenerates the target-side private key).
- Verify at the CA, then check the audit trail:

```sh
openssl crl -in crl.der -inform DER -noout -text | grep -A2 "$SERIAL"
curl "$API/api/v1/services/$SERVICE_ID/revocations" -H "Authorization: Bearer $TOKEN"
```

Watch for `RevocationFailed` (Critical), raised only after
`CertificateJobs:Revocation:MaxAttempts` give-up retries; a row still `Pending` with a
scheduled next attempt means the retry worker will keep trying (its `lastError` may be empty
when the worker, not the request, owns the current attempt), so keep
`CertificateJobs:Revocation:Enabled=true` wherever revocation is used. If the API itself is
unavailable, the same CA-side revocation can be performed with the ACME account key
configured in `SmallstepAcme:AccountKeySecretRef` against the `revokeCert` URL published by
the ACME directory — no other authorization is accepted by step-ca.

## 3. PostgreSQL backup, restore and upgrade

### 3.1 Backup schedule

Take a logical dump on a schedule (e.g. nightly) plus before every schema upgrade:

**Compose:**

```sh
docker compose exec -T postgres pg_dump -U trustforge -d trustforge -Fc > trustforge.dump
```

**Bare metal** (the cluster is local, so run `pg_dump` as the `postgres` OS user; there is no
container to exec into):

```sh
sudo -u postgres pg_dump -U trustforge -d trustforge -Fc > trustforge.dump
```

A `trustforge-pg_dump.service` + `.timer` pair in `/etc/systemd/system/` replaces the "nightly"
schedule there; copy the dump off-host, because unlike a Compose volume it is just a directory on
the machine that is being backed up.

`-Fc` (custom format) is compressed and supports selective, parallel restore. For
point-in-time recovery (PITR) beyond logical dumps, enable WAL archiving
(`archive_mode=on`, `archive_command`) and take periodic base backups (`pg_basebackup`);
restore by replaying WAL to the target time. Logical dumps are sufficient for the lab and
for recovering to the dump instant; PITR is recommended for production RPO < 24h. On bare metal
PITR matters more than the container path implies: PostgreSQL is a peer unit on the same host
rather than a sidecar, so host loss takes the database with the application.

A **complete** application backup is the dump **plus** the CA data, the issued-bundle store, the
DNS config, every target filesystem, and the secret store (section 1). Under Compose those are the
`trustforge-certificate-artifacts` and `trustforge-dns-config` volumes; on a bare-metal host they are
`/var/lib/trustforge/artifacts`, `/etc/trustforge/dns` and `/etc/trustforge/secrets`:

```sh
tar -czf dns-config.tgz    -C /etc/trustforge dns
tar -czf artifacts.tgz     -C /var/lib/trustforge artifacts
tar -czf secrets.tgz       -C /etc/trustforge secrets      # private: encrypt before shipping
```
The lab `drill-backup.sh` captures all of these and writes a `manifest.json` with row counts and the
dump SHA-256.

### 3.2 Restore runbook

Order matters. The full lab procedure is `drill-restore.sh`; the production equivalent:

1. Stop the application workers (no new writes).
2. Restore the secret store so every `secret://…` reference resolves again.
3. Restore PostgreSQL into an empty database **before** starting TrustForge:

   **Compose:**
   ```sh
   docker compose up -d postgres        # wait until healthy
   docker compose exec -T postgres pg_restore -U trustforge -d trustforge \
       --no-owner --no-privileges --exit-on-error < trustforge.dump
   ```
   **Bare metal:** create an empty database first (the dump owns its tables, so drop or rename the
   live one rather than restoring on top of it), then restore as that role:
   ```sh
   sudo systemctl stop trustforge
   sudo -u postgres dropdb --if-exists trustforge
   sudo -u postgres createdb -O trustforge trustforge
   sudo -u postgres pg_restore -U trustforge -d trustforge \
       --no-owner --no-privileges --exit-on-error < trustforge.dump
   ```
   `--no-owner --no-privileges` avoids role mismatches; `--exit-on-error` fails loudly.
4. Restore the CA volume **before** step-ca first starts (section 2.3).
5. Restore the artifacts and dns-config volumes before starting TrustForge. On a bare-metal host
   these are directories: restore `/var/lib/trustforge/artifacts` and, if the DNS zones were lost,
   `/etc/trustforge/dns` — then confirm the owner is still `trustforge:trustforge` with mode 0750,
   since `ProtectSystem=strict` gives the service no other writable path to fall back on.
6. Restore each target filesystem (registrations, releases, keys, `current` symlink), then
   restart the target services. **Never rebuild the target image to restore it** — in the
   lab the SSH host keys are baked into the image and rebuilding changes the pinned
   fingerprint.
7. Start TrustForge. Its entrypoint runs `dotnet TrustForge.dll --migrate`; because the dump
   already contains `__EFMigrationsHistory`, this is a no-op when the dump matches the
   image's migrations. On a bare-metal host the same migration is the unit's `ExecStartPre`.
   Then start the OIDC issuer dependency.
8. Verify: row counts match the backup manifest, `/health/ready` returns ready, and a fresh
   issuance job for a known service reaches `Succeeded` (this proves the restored CA keys,
   DNS, SSH target and pipeline all work together). The lab asserts exactly this.

### 3.3 Upgrade / migration procedure

TrustForge applies checked-in EF Core migrations only; it never auto-generates schema at
runtime.

1. Back up PostgreSQL (3.1) and the CA volume (2.2).
2. Build the new image. On start it runs `--migrate`, applying any pending migrations
   forward-only. Migrations are additive and idempotent; the readiness endpoint returns 503
   while migrations are pending. On a bare-metal host, re-run
   `sudo ./deploy/bare-metal/install.sh --yes --skip-postgres` with the new checkout: it stages a
   new release under `/opt/trustforge/app/`, flips the `current` symlink atomically, and the unit's
   `ExecStartPre` applies the pending migrations on the next start. `--skip-postgres` is what keeps
   it from touching your cluster or re-issuing `CREATE ROLE`, and the recorded password in
   `/etc/trustforge/secrets/database-password` is reused rather than regenerated.
3. To apply migrations explicitly without starting the API:
   ```sh
   dotnet run --project TrustForge.Api -- --migrate
   ```
   On an installed host, let systemd supply the environment rather than parsing
   `/etc/trustforge/trustforge.env` in a shell — the file is EnvironmentFile syntax, and the
   connection string contains `;`, which bash would treat as a command separator:
   ```sh
   sudo systemctl stop trustforge
   sudo systemd-run --wait --collect --unit=trustforge-migrate \
       -p EnvironmentFile=/etc/trustforge/trustforge.env \
       -p User=trustforge -p Group=trustforge \
       /opt/dotnet/dotnet /opt/trustforge/app/current/TrustForge.dll --migrate
   ```
   `--migrate` exits before Kestrel or any DNS listener starts (`TrustForge.Api/Program.cs:74-80`)
   and needs only `ConnectionStrings:TrustForge`, not the OIDC settings. The unit's `ExecStartPre` is
   the normal single migration site; two concurrent `--migrate` runs are not safe.
4. Verify `/health/ready` and run a smoke issuance job.

**Authoring convention** (for developers): migrations live in
`TrustForge.Persistence/Migrations` with sequential IDs `yyyyMMddNNNN_Name`. Scaffold with
`dotnet ef migrations add <Name> --project TrustForge.Persistence --startup-project TrustForge.Api --output-dir Migrations`,
then rename the generated files and the `[Migration("…")]` attribute to the next sequential
ID. After any model change, `dotnet ef migrations has-pending-model-changes` must report no
pending changes before commit. The current migration chain ends at
`202611150003_ExpiryReminders` (nullable `certificate_alerts.job_id`, partial unique indexes,
`dedupe_key`).

**Upgrading a database that already holds production data:** restore a production dump into
a staging database, run the new image's `--migrate` against it, and confirm the pending
migrations apply cleanly and the readiness check passes before promoting. The lab restore
drill rehearses the surrounding mechanics — it restores a *populated* dump and then starts
the new image, whose `--migrate` runs safely against existing data (a no-op when the dump
already matches the image's migrations) — but rehearse a genuine old-schema → new-schema
upgrade on staging before each production upgrade. The lab's `drill-migration.sh` rehearses
exactly this: it seeds production-like rows at the `202611150001_DeploymentVersionsAndAlerts`
baseline, upgrades through the real `--migrate` path, and asserts data preservation, the new
column defaults/indexes/constraints, idempotent re-runs and new-shape writes — and that a
database with incompatible live data (a duplicate active job for one service) is rejected
with PostgreSQL `23505` and rolled back per migration, leaving the schema at the baseline.

## 4. Key and credential rotation

| Credential | Where referenced | Rotation |
| --- | --- | --- |
| PostgreSQL password | `ConnectionStrings:TrustForge`, Compose `POSTGRES_PASSWORD`, or `/etc/trustforge/trustforge.env` on a bare-metal host | Change the role password and the connection secret together; restart the app. No schema impact. **Compose:** `ALTER ROLE` then recreate with the new `.env`. **Bare metal:** `sudo -u postgres psql -c "ALTER ROLE trustforge PASSWORD '...'"`, update the same value in `/etc/trustforge/trustforge.env` **and** `/etc/trustforge/secrets/database-password` (the installer reuses the latter), then `systemctl restart trustforge`. |
| DNS console administrator | embedded Technitium `auth.config` in the dns-config volume / `/etc/trustforge/dns` | Rotate **inside the DNS console** (or its API). `DNS_SERVER_ADMIN_PASSWORD_FILE` is read only while `auth.config` does not exist, so editing it later changes nothing — see BAREMETAL.md. |
| SSH deployer key | per-service `sshCredentialRef` → secret JSON `{username, privateKeyPem}` | Generate a new key pair, append the new public key to each target's `authorized_keys`, update the secret, verify with `POST /services/{id}/connection-test`, then remove the old public key. The pinned **host** key is separate and unchanged. |
| SSH host key (target) | per-service `hostKeyFingerprint` | If a target host key changes, update the service's pinned fingerprint out-of-band; a mismatch aborts every remote operation before it runs. |
| DNS API token | `TechnitiumDns:ApiTokenSecretRef` | Create a new least-privilege token for the challenge-zone user, update the secret, restart the worker, revoke the old token. |
| ACME account key | `SmallstepAcme:AccountKeySecretRef` | See 2.4 (new account; no target impact). |
| OIDC issuer signing keys | external issuer (Keycloak) | Rotate in the issuer; TrustForge validates via the issuer's JWKS automatically. Update `Authentication:Authority`/`Audience` only if the realm changes. |

Secret values are resolved at runtime through `ISecretResolver` and are never persisted or
logged. The shipped `EnvironmentSecretResolver` resolves `secret://env/NAME` and
`secret://file//<abs>`; production should plug a vault/KMS-backed resolver (see
[HSM-KMS-HA-EVALUATION.md](HSM-KMS-HA-EVALUATION.md)).

## 5. Disaster recovery

### 5.1 Failure domains

| Loss | Impact | Recovery |
| --- | --- | --- |
| TrustForge container/host | API + DNS + worker down; in-flight jobs stall | Restart/recreate the container, or `systemctl restart trustforge` on a bare-metal host (`journalctl -u trustforge` for the reason). Jobs resume from persisted state after lease expiry (fencing tokens prevent double writes). DNS config survives in its volume, or in `/etc/trustforge/dns` on a host. |
| PostgreSQL data | All job/service/version/alert history lost | Restore the dump (3.2). Active jobs re-claim from restored state. On bare metal the cluster is a unit on the same host, so this is lost *with* the host unless dumps or WAL archiving go off-box. |
| step-ca volume | CA keys lost; cannot issue or validate against the old root | Restore the CA volume before first start (2.3). If no backup exists, stand up a new CA, distribute the new root, and re-issue every service. |
| artifacts volume | Issued public bundles lost | Restore the volume (`/var/lib/trustforge/artifacts` on a host), or re-issue (bundles are reproducible from the CA). Deployment history references remain in PostgreSQL. |
| dns-config volume | Zone + token lost | Restore the volume (`/etc/trustforge/dns` on a host), or recreate the zone/token and update the DNS secret. On a host, recreating the directory from empty also re-applies the `DNS_SERVER_*` seed — see BAREMETAL.md before doing that. |
| A target filesystem | That target's keys/registrations/served cert lost | Restore the target tar; if unrecoverable, re-register the service and run a fresh job (generates a new target key pair). |
| Secret store | References resolve to nothing | Restore the secret store; the database alone is insufficient. |

### 5.2 Manual recovery runbook (no backup of a component)

If a component cannot be restored from backup, rebuild it forward:

1. Restore PostgreSQL from the newest dump.
2. If the CA is gone, initialize a new step-ca (patched), extract the new root, update
   `SmallstepAcme:RootCertificatePath` and every target trust store.
3. Recreate the DNS zone and least-privilege token; update the DNS secret.
4. For each managed service, run a fresh issuance job. The pipeline regenerates the target
   key pair, issues under the (new) CA, stages, activates, verifies and records a new
   deployment version. The service keeps serving its old certificate until the new one is
   verified, so there is no outage during re-issuance.
5. Confirm `/health/ready`, alert delivery, and that expiry reminders resume.

## 6. Monitoring

### 6.1 Health endpoints

- `GET /health/live` — process liveness (anonymous).
- `GET /health/ready` — PostgreSQL reachable **and** no pending migrations; returns 503
  otherwise (anonymous). Use this for load-balancer readiness and upgrade gating.

There is no Prometheus `/metrics` endpoint today; monitor via the health endpoints, the
alert stream, and SQL dashboards below. Adding an OpenTelemetry/Prometheus exporter is a
future enhancement.

### 6.2 Alerts

Terminal failures and expiry reminders are durable rows in `certificate_alerts`, delivered
at least once to `CertificateJobs:Alerts:WebhookUrl` (or logged as structured events when no
webhook is set). Receivers must dedupe by alert `id`.

| Kind | Severity | Meaning |
| --- | --- | --- |
| `JobFailed` | Warning | Issuance failed before activation; old certificate still served. |
| `DeploymentRolledBack` | Warning | Activation/verify failed; rolled back to the previous release. |
| `RollbackFailed` | **Critical** | Rollback itself failed; manual intervention required. |
| `CertificateExpiring` | Warning | Active certificate inside the reminder window (no job; deduped per certificate). |
| `CertificateRevoked` | **Critical** for `KeyCompromise`/`CaCompromise`, Warning otherwise | A certificate was revoked at the CA (deduped by `revoked:{serial}`, references the issuing job). |
| `RevocationFailed` | **Critical** | Revocation give-up after `CertificateJobs:Revocation:MaxAttempts`; the CA does not list that serial. |

Delivery state machine: `Pending → Delivered`, or `Pending → Failed` after
`CertificateJobs:Alerts:MaxAttempts` bounded-exponential retries. Query
`GET /api/v1/certificate-alerts?deliveryState=Failed` for undeliverable alerts.

### 6.3 Dashboard SQL

```sql
-- Stuck / failing jobs
SELECT state, count(*) FROM certificate_jobs GROUP BY state;

-- Jobs active longer than the lease window (possible stalled worker)
SELECT id, state, worker_lease_expires_at
FROM certificate_jobs
WHERE state IN ('Queued','Connecting','GeneratingCsr','CreatingOrder','AwaitingChallenge',
                'Signing','Staging','Activating','Verifying')
  AND worker_lease_expires_at < now();

-- Certificates expiring soon (active deployments)
SELECT s.name, v.certificate_not_after
FROM managed_services s
JOIN deployment_versions v ON v.service_id = s.id AND v.status = 'Active'
WHERE v.certificate_not_after <= now() + interval '7 days'
ORDER BY v.certificate_not_after;

-- Undelivered alerts
SELECT kind, severity, delivery_state, attempt_count, last_error
FROM certificate_alerts
WHERE delivery_state <> 'Delivered'
ORDER BY occurred_at DESC;

-- Revocations: pending work, give-ups, and what the CA was told
SELECT state, reason, count(*) FROM certificate_revocations GROUP BY state, reason;
SELECT id, serial, reason, state, attempt_count, next_attempt_at, last_error
FROM certificate_revocations
WHERE state = 'Pending'
ORDER BY requested_at;

-- Transactional wake listener (LISTEN/NOTIFY); 0 rows => worker is polling-only
SELECT count(*) FROM pg_stat_activity
WHERE application_name = 'trustforge-job-listener';
```

### 6.4 Audit export

`GET /api/v1/audit/export` (PlatformAdmin / CertificateOperator / Auditor) returns a JSON
bundle `{generatedAt, filters, jobs, deploymentVersions, alerts, revocations}` with
string-serialized enums, filterable by `serviceId`, `from`, `to`, `limit`. Use it for
periodic compliance exports and incident timelines. It is read-only and reflects the durable
PostgreSQL history, including who revoked which serial and why.

### 6.5 Transactional wake (LISTEN/NOTIFY)

Job creation issues `NOTIFY trustforge_job_submitted` in the same transaction as the job
insert, and each worker holds a dedicated `LISTEN` connection
(`application_name = 'trustforge-job-listener'`, visible in `pg_stat_activity`) that wakes it
immediately. This is a latency optimization over the durable queue, not a correctness
dependency: the `certificate_jobs` row is the source of truth, and `PollInterval` polling
remains the fallback. A missed notification (restart, reconnect, DB outage) only delays a job
until the next poll. Scheduled retries (`next_attempt_at`) are picked up by polling, not by
NOTIFY. Toggle with `CertificateJobs:Worker:NotificationEnabled` (Compose
`TRUSTFORGE_WORKER_NOTIFICATION_ENABLED`, default `true`); set `false` to run polling-only.

For multi-instance deployments, NOTIFY broadcasts to every listener, but `FOR UPDATE SKIP
LOCKED` plus a fresh fencing token per claim still ensures each job is processed by exactly
one worker. If the listener count in `pg_stat_activity` is zero while workers are running,
they have fallen back to polling — expect up to one `PollInterval` of added latency per job,
not lost jobs.

## 7. Lab rehearsal reference

The disposable lab (`dev/acme-lab/`) rehearses every procedure above against the real
pipeline:

```sh
cd dev/acme-lab
./setup.sh              # build images, init CA, register services, first jobs
./drill-deployment.sh   # rollback / rollback-failure / retention
./drill-backup.sh       # pg_dump + CA/artifacts/dns volumes + target layer + secrets + manifest
./drill-restore.sh      # down -v, restore everything, assert counts, fresh issuance job
./drill-notification.sh # LISTEN/NOTIFY wake A/B (poll-bound control vs notify), restores base config
./drill-migration.sh    # real old→new schema upgrade on seeded side databases via --migrate
./drill-renewal.sh      # concurrency guard + automatic renewal
./drill-revocation.sh   # CRL precondition, RBAC, real ACME revocation, replay, CA-outage retry
./verify.sh             # asserts all Phase 4/5/6/7 completion conditions
```

Run backup/restore **before** `drill-renewal.sh`: the restore drill issues a fresh `svc1`
job to prove CA recovery, and registering the renewal-enabled service afterwards keeps the
renewal assertions free of post-restore scheduler races. Run
`drill-notification.sh` **before** `drill-renewal.sh` too: it restores the base worker config
when it finishes and leaves Keycloak ready, and its `notificationDrill` result is already in
`lab-state.json` so `verify.sh` exercises the notification section. `drill-migration.sh`
also runs **before** `drill-renewal.sh`: it upgrades disposable side databases through a
one-off `--migrate` container without recreating the app or touching the main lab database.
No step needs to be adjacent to another: the renewal-enabled service renews on every minimum
interval for the life of the lab and can take over the shared target deployment path at any
moment, so `verify.sh` derives its renewal and fingerprint assertions from live state — the
release that currently owns `/etc/trustforge-demo/current` and the measured gaps between
renewals — rather than assuming the last recorded job still owns it.
`verify.sh` includes expiry-reminder, audit-export and (when those drills
ran) backup/restore, notification and migration-upgrade sections.

These drills are container-shaped: they shell into `postgres` and `target` services with
`docker compose exec`. Against a bare-metal TrustForge they still work, because they reach the API,
the CA and the targets over the network — set `TF_API_URL=http://127.0.0.1:5000` and skip only the
steps that exec into the lab's own containers. The bare-metal equivalent of the backup/restore and
migration drills is the checklist at the end of [BAREMETAL.md](BAREMETAL.md), which is run by hand on
the host rather than asserted by a script.

### 7.1 Real CA and real target acceptance (`dev/acceptance/`)

The lab proves the pipeline on disposable containers; `dev/acceptance/` repeats §7's
issuance, deployment-verification and revocation procedures against **your** CA and **your**
targets. `preflight.sh` is read-only and validates every external input before an ACME order
exists (CA directory over TLS pinned to the root, `revokeCert` present, CRL decodable with a
future `nextUpdate`, EC P-256 account key, API readiness, token audience plus `PlatformAdmin`,
Technitium token permission on the challenge zone, SAN/zone containment, target reachability and
pinned host key). `drill.sh` then registers each inventory host, drives one real DNS-01 issuance to
`Active` + `Healthy`, compares the certificate the target is actually serving against the job's
fingerprint, revokes only the certificate it minted, replays the `Idempotency-Key` to prove no
second CA call, and waits for the serial on the CRL.

Two premises that the lab alone cannot settle:

- the target-side registration `/etc/trustforge/services/<GUID without dashes>.json` can only be
  written **after** `POST /api/v1/services` returns the GUID, and `validate` executes the registered
  health action — so `connection-test` legitimately fails before the service is serving TLS on those
  paths;
- CRL publication latency is a CA setting, not a TrustForge one: step-ca serves `/1.0/crl` only with
  a `crl` block in its provisioner JSON, and a revoked serial appears promptly only when
  `generateOnRevoke` is true. Without it, raise `TF_CRL_PROPAGATION_SECONDS` to the CA's own renewal
  interval instead of reading the timeout as a lost revocation.

Verified on 2026-11-23 against `dev/acme-lab` as the "real" environment (step-ca 0.30.2, real
Technitium DNS, real SSH target): `preflight.sh` 42 PASS / 0 FAIL of 42, `drill.sh` 12 PASS / 0 FAIL
of 12, and `dev/acme-lab/verify.sh` afterwards 111 PASS / 0 FAIL / 0 SKIP — the drill left no
background renewals and the target serving a valid certificate. See `dev/acceptance/README.md` for
the target-side and control-plane prerequisites.
