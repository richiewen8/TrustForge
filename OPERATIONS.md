# TrustForge operations manual

This manual is for operators who run TrustForge in production: where durable state lives,
how to back it up and restore it, how to rotate keys, how to upgrade the schema, and how to
monitor the system. The backup/restore procedure here is rehearsed end to end by the
disposable lab drills `dev/acme-lab/drill-backup.sh` and `dev/acme-lab/drill-restore.sh`.

TrustForge is a single application container (API + embedded Technitium DNS + certificate
worker) with PostgreSQL as its persistence dependency and an external Smallstep `step-ca`
as the ACME issuer. See [DEPLOYMENT.md](DEPLOYMENT.md) for first-time setup and
[CERTIFICATE-PIPELINE.md](CERTIFICATE-PIPELINE.md) for the durable stage protocol.

## 1. Where state lives

| State | Location | Secret? | Backup method |
| --- | --- | --- | --- |
| Jobs, transitions, services, deployment versions, alerts | PostgreSQL (`certificate_jobs`, `certificate_job_transitions`, `managed_services`, `deployment_versions`, `certificate_alerts`) | No private keys; secret **references** only | `pg_dump -Fc` |
| CA root/intermediate keys, ACME account/order DB, provisioner config | step-ca data volume (`/home/step`) | **Yes — CA keys** | volume tar (CA stopped) |
| Issued public certificate bundles | `trustforge-certificate-artifacts` volume | No (public material) | volume tar |
| DNS zone files, users, API tokens | `trustforge-dns-config` volume (embedded Technitium) | API token hashes | volume tar |
| Target service/action registrations, releases, **per-job private keys**, served `current` symlink | each Linux target's filesystem (`/etc/trustforge`, `/var/lib/trustforge`, `/etc/trustforge-demo`) | **Yes — target private keys** | target filesystem tar |
| ACME account key, DNS API token, SSH deployer credential, CA root PEM | secret store referenced by `secret://…` (lab: `dev/acme-lab/secrets/`) | **Yes** | secret-store backup |

Two invariants shape every procedure below:

- **Private keys never enter PostgreSQL, logs or checkpoints.** They are generated on the
  target and stay there; the CA keys stay in the step-ca volume. A PostgreSQL dump alone is
  therefore *not* a full backup — you must also capture the CA volume and the targets.
- **The database stores only secret references** (`secret://env/NAME`, `secret://file/<abs>`).
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

Stop step-ca first so the badger DB is consistent, then archive its data volume:

```sh
docker compose stop step-ca
docker run --rm -v <project>_stepca-data:/data:ro --entrypoint sh <helper-image> \
    -c 'tar -czf - -C /data .' > stepca.tar.gz
docker compose up -d step-ca
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

After restore, the CA root PEM distributed to TrustForge (`SmallstepAcme:RootCertificatePath`)
and to every target must be the **restored** root, not a freshly generated one.

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
  fingerprint (`renewal-{fingerprint}`). A lead time ≥ certificate lifetime is safe: the
  minimum interval prevents a renewal loop.
- Expiry reminders are independent of renewal: the `ExpiryReminderWorker` scans every
  `CertificateJobs:Expiry:ScanInterval` and raises a `CertificateExpiring` (Warning) alert
  for every enabled service whose active certificate is inside
  `CertificateJobs:Expiry:ReminderWindow`, deduped per service+fingerprint
  (`expiring:{serviceId}:{fingerprint}`). Reminders fire even for renewal-enabled services
  as a safety net. Tune the window so operators have lead time to act if renewal fails.
- Durations use the .NET constant format `d.hh:mm:ss`. **`25:00:00` parses as 25 days, not
  25 hours** — use `1.01:00:00` for 25 hours.

## 3. PostgreSQL backup, restore and upgrade

### 3.1 Backup schedule

Take a logical dump on a schedule (e.g. nightly) plus before every schema upgrade:

```sh
docker compose exec -T postgres pg_dump -U trustforge -d trustforge -Fc > trustforge.dump
```

`-Fc` (custom format) is compressed and supports selective, parallel restore. For
point-in-time recovery (PITR) beyond logical dumps, enable WAL archiving
(`archive_mode=on`, `archive_command`) and take periodic base backups (`pg_basebackup`);
restore by replaying WAL to the target time. Logical dumps are sufficient for the lab and
for recovering to the dump instant; PITR is recommended for production RPO < 24h.

A **complete** application backup is the dump **plus** the CA volume, artifacts volume,
dns-config volume, every target filesystem, and the secret store (section 1). The lab
`drill-backup.sh` captures all of these and writes a `manifest.json` with row counts and the
dump SHA-256.

### 3.2 Restore runbook

Order matters. The full lab procedure is `drill-restore.sh`; the production equivalent:

1. Stop the application workers (no new writes).
2. Restore the secret store so every `secret://…` reference resolves again.
3. Restore PostgreSQL into an empty database **before** starting TrustForge:
   ```sh
   docker compose up -d postgres        # wait until healthy
   docker compose exec -T postgres pg_restore -U trustforge -d trustforge \
       --no-owner --no-privileges --exit-on-error < trustforge.dump
   ```
   `--no-owner --no-privileges` avoids role mismatches; `--exit-on-error` fails loudly.
4. Restore the CA volume **before** step-ca first starts (section 2.3).
5. Restore the artifacts and dns-config volumes before starting TrustForge.
6. Restore each target filesystem (registrations, releases, keys, `current` symlink), then
   restart the target services. **Never rebuild the target image to restore it** — in the
   lab the SSH host keys are baked into the image and rebuilding changes the pinned
   fingerprint.
7. Start TrustForge. Its entrypoint runs `dotnet TrustForge.dll --migrate`; because the dump
   already contains `__EFMigrationsHistory`, this is a no-op when the dump matches the
   image's migrations. Then start the OIDC issuer dependency.
8. Verify: row counts match the backup manifest, `/health/ready` returns ready, and a fresh
   issuance job for a known service reaches `Succeeded` (this proves the restored CA keys,
   DNS, SSH target and pipeline all work together). The lab asserts exactly this.

### 3.3 Upgrade / migration procedure

TrustForge applies checked-in EF Core migrations only; it never auto-generates schema at
runtime.

1. Back up PostgreSQL (3.1) and the CA volume (2.2).
2. Build the new image. On start it runs `--migrate`, applying any pending migrations
   forward-only. Migrations are additive and idempotent; the readiness endpoint returns 503
   while migrations are pending.
3. To apply migrations explicitly without starting the API:
   ```sh
   dotnet run --project TrustForge.Api -- --migrate
   ```
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
| PostgreSQL password | `ConnectionStrings:TrustForge`, Compose `POSTGRES_PASSWORD` | Change the role password and the connection secret together; restart the app. No schema impact. |
| SSH deployer key | per-service `sshCredentialRef` → secret JSON `{username, privateKeyPem}` | Generate a new key pair, append the new public key to each target's `authorized_keys`, update the secret, verify with `POST /services/{id}/connection-test`, then remove the old public key. The pinned **host** key is separate and unchanged. |
| SSH host key (target) | per-service `hostKeyFingerprint` | If a target host key changes, update the service's pinned fingerprint out-of-band; a mismatch aborts every remote operation before it runs. |
| DNS API token | `TechnitiumDns:ApiTokenSecretRef` | Create a new least-privilege token for the challenge-zone user, update the secret, restart the worker, revoke the old token. |
| ACME account key | `SmallstepAcme:AccountKeySecretRef` | See 2.4 (new account; no target impact). |
| OIDC issuer signing keys | external issuer (Keycloak) | Rotate in the issuer; TrustForge validates via the issuer's JWKS automatically. Update `Authentication:Authority`/`Audience` only if the realm changes. |

Secret values are resolved at runtime through `ISecretResolver` and are never persisted or
logged. The shipped `EnvironmentSecretResolver` resolves `secret://env/NAME` and
`secret://file/<abs>`; production should plug a vault/KMS-backed resolver (see
[HSM-KMS-HA-EVALUATION.md](HSM-KMS-HA-EVALUATION.md)).

## 5. Disaster recovery

### 5.1 Failure domains

| Loss | Impact | Recovery |
| --- | --- | --- |
| TrustForge container/host | API + DNS + worker down; in-flight jobs stall | Restart/recreate the container. Jobs resume from persisted state after lease expiry (fencing tokens prevent double writes). DNS config survives in its volume. |
| PostgreSQL data | All job/service/version/alert history lost | Restore the dump (3.2). Active jobs re-claim from restored state. |
| step-ca volume | CA keys lost; cannot issue or validate against the old root | Restore the CA volume before first start (2.3). If no backup exists, stand up a new CA, distribute the new root, and re-issue every service. |
| artifacts volume | Issued public bundles lost | Restore the volume, or re-issue (bundles are reproducible from the CA). Deployment history references remain in PostgreSQL. |
| dns-config volume | Zone + token lost | Restore the volume, or recreate the zone/token and update the DNS secret. |
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

-- Transactional wake listener (LISTEN/NOTIFY); 0 rows => worker is polling-only
SELECT count(*) FROM pg_stat_activity
WHERE application_name = 'trustforge-job-listener';
```

### 6.4 Audit export

`GET /api/v1/audit/export` (PlatformAdmin / CertificateOperator / Auditor) returns a JSON
bundle `{generatedAt, filters, jobs, deploymentVersions, alerts}` with string-serialized
enums, filterable by `serviceId`, `from`, `to`, `limit`. Use it for periodic compliance
exports and incident timelines. It is read-only and reflects the durable PostgreSQL history.

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
./verify.sh             # asserts all Phase 4/5/6 completion conditions
```

Run backup/restore **before** `drill-renewal.sh`: the restore drill issues a fresh `svc1`
job to prove CA recovery, and registering the renewal-enabled service afterwards keeps the
"exactly one renewal job" assertion free of post-restore scheduler races. Run
`drill-notification.sh` **before** `drill-renewal.sh` too: it restores the base worker config
when it finishes, so `drill-renewal.sh` → `verify.sh` stay adjacent (verify must run within
the 2-minute minimum renewal interval), and its `notificationDrill` result is already in
`lab-state.json` so `verify.sh` exercises the notification section. `drill-migration.sh`
also runs **before** `drill-renewal.sh`: it upgrades disposable side databases through a
one-off `--migrate` container without recreating the app or touching the main lab database,
so the renewal → verify window stays intact and its `migrationDrill` result is in
`lab-state.json`. `verify.sh` includes expiry-reminder, audit-export and (when those drills
ran) backup/restore, notification and migration-upgrade sections.