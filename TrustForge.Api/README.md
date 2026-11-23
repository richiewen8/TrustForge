# TrustForge.Api

Independent HTTP API host for TrustForge. The first endpoints register Linux managed services, create manual certificate jobs, and read service/job details. All API routes require a verified JWT; there is no anonymous development bypass.

## Local PostgreSQL

Docker Compose is provided in `docker-compose.trustforge-dev.yml`. Copy `trustforge-dev.env.example` to the ignored `.env.trustforge`, replace the placeholder password, then start PostgreSQL:

```powershell
Copy-Item trustforge-dev.env.example .env.trustforge
# Edit .env.trustforge and replace the placeholder password.
docker compose --env-file .env.trustforge -f docker-compose.trustforge-dev.yml up -d
```

The same Compose file provides a local-only Keycloak realm. Start the development issuer with `docker compose --env-file .env.trustforge -f docker-compose.trustforge-dev.yml up -d keycloak`. It listens on loopback port 8180 and imports realm `trustforge-dev`, audience `trustforge-api`, and a `PlatformAdmin` user whose password comes from the ignored env file. The imported user includes the required email and name profile fields so direct password grants work on current Keycloak versions. The client explicitly maps `sub`, audience, and realm roles into access tokens. Keycloak `start-dev` and HTTP are for local development only.

## Certificate job worker

PostgreSQL-backed claiming and lease recovery are implemented. The worker is intentionally disabled by default (`CertificateJobs:Worker:Enabled=false`, or `TRUSTFORGE_WORKER_ENABLED=false` in Compose). When enabled in production it uses the real pipeline processor: Smallstep ACME, Technitium DNS-01, SSH.NET with pinned host keys, Linux target-side CSR/private-key generation, staged release activation, health verification and rollback. The worker uses a renewable two-minute fencing-token lease by default and retries processor errors with bounded exponential delay. The durable `certificate_jobs` row is the queue (an outbox equivalent); each job insert issues a transactional PostgreSQL `NOTIFY` (`trustforge_job_submitted`) and a dedicated `LISTEN` connection wakes the worker at once. `CertificateJobs:Worker:NotificationEnabled` (default `true`, Compose `TRUSTFORGE_WORKER_NOTIFICATION_ENABLED`) toggles this wake; `PollInterval` polling remains the loss-safe fallback, so a missed notification only costs latency, never correctness.

For isolated state-machine development, set `ASPNETCORE_ENVIRONMENT=Development` and `CertificateJobs:Simulation:Enabled=true` (Compose: `TRUSTFORGE_SIMULATION_ENABLED=true`). The simulation advances each durable stage and ends at `Simulated`; it does not issue a certificate or connect to managed hosts. Production refuses this setting. See [CERTIFICATE-PIPELINE.md](../CERTIFICATE-PIPELINE.md) for recovery semantics and [remote-helper/README.md](../remote-helper/README.md) for Linux host setup.

Real execution requires Smallstep ACME and Technitium settings from `.env.trustforge.example`, an `ISecretResolver` reference for the ACME account key, DNS API token and per-service SSH credential JSON, plus a persistent artifact volume. `SmallstepAcme:RootCertificatePath` is required for the real pipeline: issued certificates are validated against that CA root (chain, fingerprint, CSR public-key correspondence, exact SAN match, server-auth EKU, key strength and validity window) before anything is persisted or deployed. `SmallstepAcme:MaximumCertificateLifetime` (default 90 days) bounds the accepted certificate lifetime until certificate profiles exist. The SSH account's public key must be registered on each target and its sudo rule limited to `/usr/local/sbin/trustforge-certctl`. Install the helper and root-owned service/action registrations before registering the service in TrustForge.

### Renewal, expiry reminders and alerts

Background workers (the first three require the pipeline worker to be enabled; the revocation retry worker only requires `CertificateJobs:Revocation:Enabled`):

- `RenewalSchedulerWorker` (`CertificateJobs:Renewal`): scans enabled services whose active certificate enters the per-service `renewalLeadTime` window and creates one renewal job per service. `ScanInterval` (default 5 minutes) and `MinimumRenewalInterval` (default 1 hour) plus the fingerprint idempotency key `renewal-{fingerprint}` bound the rate: one certificate is never renewed twice, and no service gets more than one renewal per interval. They do not stop renewal while a service stays in its own window — set `renewalLeadTime` below the certificate lifetime. A database-level partial unique index allows only one active job per service.
- `ExpiryReminderWorker` (`CertificateJobs:Expiry`): scans active certificates whose `certificateNotAfter` falls within `ReminderWindow` (default 7 days) every `ScanInterval` (default 1 hour) and raises a `CertificateExpiring` Warning alert. Reminders are independent of the renewal policy (they fire even for services with `renewalEnabled=false`) and are deduplicated per service+fingerprint via `dedupeKey`, so each certificate produces at most one reminder.
- `CertificateAlertDeliveryWorker` (`CertificateJobs:Alerts`): delivers pending alerts to `WebhookUrl` (when unset, alerts are emitted as structured log events only). `PollInterval` (default 5 seconds), `VisibilityTimeout` (default 1 minute) and `MaxAttempts` (default 5) control delivery retries.
- `RevocationRetryWorker` (`CertificateJobs:Revocation`): finishes revocations whose CA call failed or was interrupted, using `PollInterval` (default 10 seconds), `VisibilityTimeout` (default 2 minutes) and `MaxAttempts` (default 5, after which the row is `Failed` and a critical `RevocationFailed` alert is raised). Set `CertificateJobs:Revocation:Enabled=false` to run without the retry loop; `POST /api/v1/services/{id}/revocations` still attempts the CA inline and reports `202 pending` in that case, so keep the worker enabled wherever revocation is used.

Durations use unambiguous .NET `TimeSpan` format: `25:00:00` parses as 25 **days**, so use `1.01:00:00` for 25 hours. See [OPERATIONS.md](../OPERATIONS.md) for backup/restore, key rotation and monitoring runbooks.

### End-to-end ACME lab

`dev/acme-lab/` provides a disposable, fully containerized lab that runs the real pipeline against Smallstep `step-ca`, the embedded Technitium DNS server and a Linux SSH target. From the repository root:

```sh
cd dev/acme-lab
./setup.sh     # first run creates .env; fill in the passwords and re-run
./verify.sh    # asserts issuance, deployment, cleanup and key isolation
```

See [dev/acme-lab/README.md](../dev/acme-lab/README.md) for the topology and recovery drills.

Set `ConnectionStrings__TrustForge` in the API process environment to the corresponding local connection string. The schema migration command is:

```powershell
dotnet run --project TrustForge.Api -- --migrate
```

The command only applies checked-in EF Core migrations and exits. It reads the PostgreSQL connection string from protected runtime configuration.

## Required API configuration

- `ConnectionStrings__TrustForge`: PostgreSQL connection string.
- `Authentication__Authority`: HTTPS OIDC issuer URL. For the local Keycloak development realm use `http://localhost:8180/realms/trustforge-dev`.
- `Authentication__Audience`: expected API audience.
- `Authentication__AllowInsecureLoopback`: set to `true` only in `Development` when using the loopback Keycloak HTTP issuer; the API rejects this setting outside Development and only accepts a loopback authority.

The identity token must include a `sub` claim and one of the `role` values `PlatformAdmin`, `CertificateOperator`, or `Auditor`. Operator roles can register services and create manual jobs; reader roles can inspect service and job details. Remote service and action registrations are root-managed on each Linux target; see the helper setup guide.

With Keycloak running, configure `ASPNETCORE_ENVIRONMENT=Development`, `Authentication__Authority=http://localhost:8180/realms/trustforge-dev`, `Authentication__Audience=trustforge-api`, and `Authentication__AllowInsecureLoopback=true` before starting the API. The API requires HTTPS issuers outside this explicitly enabled local-development case.

## Endpoints

- `POST /api/v1/services`: register a Linux service and constrained PEM/SSH deployment metadata. Optional `renewalEnabled` (default false) and `renewalLeadTime` (a positive duration ≤ 365 days, e.g. `1.01:00:00` for 25 hours; default 30 days) control automatic renewal.
- `GET /api/v1/services/{id}`: read a registered service.
- `POST /api/v1/services/{id}/connection-test`: connect with the pinned SSH host key and run the remote helper's validate operation; returns `{ "success": true }` or `{ "success": false, "error": ... }`. A host-key fingerprint mismatch aborts before any remote operation.
- `POST /api/v1/services/{id}/certificate-jobs`: create an idempotent manual issuance job; requires `Idempotency-Key`. Returns 409 `service_job_active` if the service already has an active job (database-level one-active-job-per-service guard).
- `GET /api/v1/services/{id}/revocations`: revocation history for a service (newest first, CA-side `serial`, `reason`, `state` `Pending`/`Revoked`/`Failed`, `attemptCount`, `revokedAt`, `lastError`); optional `limit`. Requires a reader role.
- `POST /api/v1/services/{id}/revocations`: revoke the certificate behind the service's `Active` deployment version at the CA. Requires `Idempotency-Key` and a JSON body `{"reason": "KeyCompromise"}` (one of `Unspecified`, `KeyCompromise`, `CaCompromise`, `AffiliationChanged`, `Superseded`, `CessationOfOperation`). **`PlatformAdmin` only** — narrower than issuance on purpose, because revocation is irreversible. Returns `200 {status: revoked|replayed}`, or `202 {status: pending}` when the CA is unreachable and the durable retry worker will finish it, or `409` `service_job_active` / `no_active_certificate`. The serial is read back from the stored artifact, so a record cannot drift from what was deployed. Revoking again with a different key replays the same record; the CA is asked at most once per serial.
- `GET /api/v1/certificate-revocations/{id}`: read one revocation attempt and its retry state.
- `GET /api/v1/services/{id}/deployment-versions`: per-service deployment history (staged/active/superseded/rolled-back releases, fingerprints, health and verification timestamps, and the issued certificate's `certificateNotAfter`); optional `limit`.
- `GET /api/v1/certificate-alerts`: durable alerts and their delivery state; optional `serviceId`, `deliveryState` (`Pending`/`Delivered`/`Failed`) and `limit`. Includes terminal job-failure alerts (`JobFailed`/`DeploymentRolledBack`/`RollbackFailed`, which carry a `jobId`), expiry reminders (`CertificateExpiring`, which carry no `jobId` but a `dedupeKey` of the form `expiring:{serviceId}:{fingerprint}`) and revocation alerts (`CertificateRevoked`, deduped by `revoked:{serial}`, `Critical` for key/CA compromise and `Warning` otherwise; `RevocationFailed`, `Critical`, raised only when retries are exhausted).
- `GET /api/v1/audit/export`: read-only audit bundle `{ generatedAt, filters, jobs, deploymentVersions, alerts, revocations }` for export/archival; optional `serviceId`, `from`, `to` (ISO-8601 timestamps; `from` must not be later than `to`) and `limit` (default 200, applied per section). Enums serialize as strings. Requires a reader role (`PlatformAdmin`, `CertificateOperator` or `Auditor`).
- `GET /api/v1/certificate-jobs/{id}`: read job state and its transition history.
- `GET /health/live`, `GET /health/ready`: liveness and PostgreSQL/schema readiness.

Creating a job records it as `Queued`. With the worker disabled, it remains queued; with the worker enabled, it proceeds through issuance and deployment stages and records each transition in PostgreSQL.
