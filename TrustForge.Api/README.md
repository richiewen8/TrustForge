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

The identity token must include a `sub` claim and one of the `role` values `PlatformAdmin`, `CertificateOperator`, or `Auditor`. Operator roles can register services and create manual jobs; reader roles can inspect service and job details. The certificate profile and remote helper/action identifiers are references; profile/action management is implemented in later phases.

With Keycloak running, configure `ASPNETCORE_ENVIRONMENT=Development`, `Authentication__Authority=http://localhost:8180/realms/trustforge-dev`, `Authentication__Audience=trustforge-api`, and `Authentication__AllowInsecureLoopback=true` before starting the API. The API requires HTTPS issuers outside this explicitly enabled local-development case.

## Endpoints

- `POST /api/v1/services`: register a Linux service and constrained PEM/SSH deployment metadata.
- `GET /api/v1/services/{id}`: read a registered service.
- `POST /api/v1/services/{id}/certificate-jobs`: create an idempotent manual issuance job; requires `Idempotency-Key`.
- `GET /api/v1/certificate-jobs/{id}`: read job state and its transition history.
- `GET /health/live`, `GET /health/ready`: liveness and PostgreSQL/schema readiness.

Creating a job records it as `Queued`; an execution worker is a later phase. The endpoint does not yet issue certificates or connect to the target host.
