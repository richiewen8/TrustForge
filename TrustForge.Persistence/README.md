# TrustForge.Persistence

PostgreSQL persistence for TrustForge domain records. This project persists certificate issuance/deployment jobs, their append-only transition history, and worker leases.

## Host integration

The future API/Worker host should read its PostgreSQL connection string from protected configuration or a secret store, then register the persistence services:

```csharp
services.AddTrustForgePersistence(connectionString);
```

The host controls migration timing by resolving `TrustForgeDatabaseMigrator` and calling `ApplyAsync` during a deliberate deployment/startup step. Do not put credentials in source control or call `EnsureCreated`; schema changes are managed by checked-in EF Core migrations.

## Tables

- `certificate_jobs`: current job state, version, idempotency scope, timestamps, certificate reference/fingerprint, and sanitized failure summary.
- `certificate_job_transitions`: one immutable row per state transition, keyed by `(job_id, version)` and cascading with its job.

The job row update and new transition row are committed in the same transaction. A unique PostgreSQL index enforces `(service_id, requested_by, idempotency_key)`. The `version` field is an EF Core concurrency token; stale writes return a concurrency conflict instead of overwriting newer state.

Workers claim one eligible non-terminal job with `FOR UPDATE SKIP LOCKED`, recording an owner, random fencing token, expiration and incremented attempt count in the same PostgreSQL statement. Lease time and retry scheduling use the database clock. Each worker state transition must match both the expected version and live fencing token; an expired worker cannot write after another instance reclaims the job. A process crash leaves the row available after lease expiry. Transient processing failures release the lease with bounded exponential backoff.

`ICertificateJobProcessor` implementations must resume from the persisted current state, make external side effects idempotent, and use `CertificateJobCoordinator.TransitionLeasedAsync`. A lease is not an exactly-once guarantee for external systems: each future ACME/DNS/SSH adapter must reconcile effects after a crash. The API Worker remains disabled by default until such a processor is registered.

## Current runtime boundary

The project includes checked-in migrations and a model snapshot. Apply pending migrations through the explicit host migration command (`--migrate`) before enabling workers. Never call `EnsureCreated` or place database credentials in source control.
