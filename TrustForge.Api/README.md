# TrustForge.Api

Independent HTTP API host for TrustForge. The first endpoints register Linux managed services, create manual certificate jobs, and read service/job details. All API routes require a verified JWT; there is no anonymous development bypass.

## Local PostgreSQL

Docker Compose is provided in `docker-compose.trustforge-dev.yml`. Copy `trustforge-dev.env.example` to the ignored `.env.trustforge`, replace the placeholder password, then start PostgreSQL:

```powershell
Copy-Item trustforge-dev.env.example .env.trustforge
# Edit .env.trustforge and replace the placeholder password.
docker compose --env-file .env.trustforge -f docker-compose.trustforge-dev.yml up -d
```

Set `ConnectionStrings__TrustForge` in the API process environment to the corresponding local connection string. The schema migration command is:

```powershell
dotnet run --project TrustForge.Api -- --migrate
```

The command only applies checked-in EF Core migrations and exits. It reads the PostgreSQL connection string from protected runtime configuration.

## Required API configuration

- `ConnectionStrings__TrustForge`: PostgreSQL connection string.
- `Authentication__Authority`: HTTPS OIDC issuer URL.
- `Authentication__Audience`: expected API audience.

The identity token must include a `sub` claim and one of the `role` values `PlatformAdmin`, `CertificateOperator`, or `Auditor`. Operator roles can register services and create manual jobs; reader roles can inspect service and job details. The certificate profile and remote helper/action identifiers are references; profile/action management is implemented in later phases.

## Endpoints

- `POST /api/v1/services`: register a Linux service and constrained PEM/SSH deployment metadata.
- `GET /api/v1/services/{id}`: read a registered service.
- `POST /api/v1/services/{id}/certificate-jobs`: create an idempotent manual issuance job; requires `Idempotency-Key`.
- `GET /api/v1/certificate-jobs/{id}`: read job state and its transition history.
- `GET /health/live`, `GET /health/ready`: liveness and PostgreSQL/schema readiness.

Creating a job records it as `Queued`; an execution worker is a later phase. The endpoint does not yet issue certificates or connect to the target host.
