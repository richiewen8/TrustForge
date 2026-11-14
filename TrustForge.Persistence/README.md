# TrustForge.Persistence

PostgreSQL persistence for TrustForge domain records. This project currently persists certificate issuance/deployment jobs and their append-only transition history.

## Host integration

The future API/Worker host should read its PostgreSQL connection string from protected configuration or a secret store, then register the persistence services:

```csharp
services.AddTrustForgePersistence(connectionString);
```

The host controls migration timing by resolving `TrustForgeDatabaseMigrator` and calling `ApplyAsync` during a deliberate deployment/startup step. Do not put credentials in source control or call `EnsureCreated`; schema changes are managed by checked-in EF Core migrations.

## Tables

- `certificate_jobs`: current job state, version, idempotency scope, timestamps, certificate reference/fingerprint, and sanitized failure summary.
- `certificate_job_transitions`: one immutable row per state transition, keyed by `(job_id, version)` and cascading with its job.

The job row update and new transition row are committed in the same `SaveChanges` transaction. A unique PostgreSQL index enforces `(service_id, requested_by, idempotency_key)`. The `version` field is an EF Core concurrency token; stale writes return a concurrency conflict instead of overwriting newer state.

## Current runtime boundary

The project includes a checked-in initial migration and model snapshot. It has not yet been applied to a live PostgreSQL instance because the TrustForge host and deployment connection have not been created. Configure a real connection only in a controlled runtime environment.
