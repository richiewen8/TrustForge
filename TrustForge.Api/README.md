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

PostgreSQL-backed claiming and lease recovery are implemented. The worker is intentionally disabled by default (`CertificateJobs:Worker:Enabled=false`, or `TRUSTFORGE_WORKER_ENABLED=false` in Compose). When enabled in production it uses the real pipeline processor: Smallstep ACME, Technitium DNS-01, SSH.NET with pinned host keys, Linux target-side CSR/private-key generation, staged release activation, health verification and rollback. The worker uses a renewable two-minute fencing-token lease by default and retries processor errors with bounded exponential delay.

For isolated state-machine development, set `ASPNETCORE_ENVIRONMENT=Development` and `CertificateJobs:Simulation:Enabled=true` (Compose: `TRUSTFORGE_SIMULATION_ENABLED=true`). The simulation advances each durable stage and ends at `Simulated`; it does not issue a certificate or connect to managed hosts. Production refuses this setting. See [CERTIFICATE-PIPELINE.md](../CERTIFICATE-PIPELINE.md) for recovery semantics and [remote-helper/README.md](../remote-helper/README.md) for Linux host setup.

Real execution requires Smallstep ACME and Technitium settings from `.env.trustforge.example`, an `ISecretResolver` reference for the ACME account key, DNS API token and per-service SSH credential JSON, plus a persistent artifact volume. `SmallstepAcme:RootCertificatePath` is required for the real pipeline: issued certificates are validated against that CA root (chain, fingerprint, CSR public-key correspondence, exact SAN match, server-auth EKU, key strength and validity window) before anything is persisted or deployed. `SmallstepAcme:MaximumCertificateLifetime` (default 90 days) bounds the accepted certificate lifetime until certificate profiles exist. The SSH account's public key must be registered on each target and its sudo rule limited to `/usr/local/sbin/trustforge-certctl`. Install the helper and root-owned service/action registrations before registering the service in TrustForge.

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

- `POST /api/v1/services`: register a Linux service and constrained PEM/SSH deployment metadata.
- `GET /api/v1/services/{id}`: read a registered service.
- `POST /api/v1/services/{id}/certificate-jobs`: create an idempotent manual issuance job; requires `Idempotency-Key`.
- `GET /api/v1/certificate-jobs/{id}`: read job state and its transition history.
- `GET /health/live`, `GET /health/ready`: liveness and PostgreSQL/schema readiness.

Creating a job records it as `Queued`. With the worker disabled, it remains queued; with the worker enabled, it proceeds through issuance and deployment stages and records each transition in PostgreSQL.
