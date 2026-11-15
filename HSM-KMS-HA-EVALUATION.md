# Production hardening evaluation: HSM/KMS, step-ca HA, multi-instance TrustForge

This document evaluates three production-readiness questions for TrustForge and recommends
an adoption order. It is an assessment, not an implementation: each section names the
concrete seam in the current code, the options, and the blockers to resolve first.

Current baseline: one TrustForge container (API + embedded Technitium DNS + worker),
PostgreSQL 17, a single Smallstep `step-ca` (nosql/badger backend), secrets resolved through
`ISecretResolver` (shipped implementation: `EnvironmentSecretResolver` for
`secret://env/NAME` and `secret://file/<abs>`).

## 1. HSM / KMS for key material

### 1.1 What keys exist and where they live

| Key | Today | Sensitivity |
| --- | --- | --- |
| CA root + intermediate private keys | step-ca data volume (badger), software keys | Highest — trust anchor |
| ACME account key | secret behind `SmallstepAcme:AccountKeySecretRef` | High — can issue against the CA |
| DNS API token | secret behind `TechnitiumDns:ApiTokenSecretRef` | Medium — challenge-zone write |
| SSH deployer key | secret behind per-service `sshCredentialRef` | High — root-helper access on targets |
| Target service private keys | generated on each target, never leave it | High — but already host-local |

### 1.2 step-ca HSM/KMS support

step-ca supports keeping the root/intermediate signing keys in an HSM or cloud KMS via
PKCS#11 URIs and `kms:`-style key URIs in its configuration (e.g. `kms:pkcs11:...` or a cloud
KMS provider), so the CA signs without the private key ever existing as a software file.
Recommended posture:

- **Root offline.** Keep the root key in an HSM/offline ceremony; step-ca uses an
  intermediate for day-to-day issuance. Rotate the intermediate on a schedule
  ([OPERATIONS.md](OPERATIONS.md) §2.4).
- **Intermediate in HSM/KMS** for the online CA, so a host compromise does not exfiltrate
  the signing key.
- This is a step-ca configuration change; TrustForge is unaffected because it only consumes
  the ACME API and the public root PEM (`SmallstepAcme:RootCertificatePath`).

### 1.3 TrustForge secret resolution seam

TrustForge already isolates secret access behind one interface
(`TrustForge.Core/CertificateJobs/ISecretResolver.cs`):

```csharp
ValueTask<string> ResolveAsync(string secretReference, CancellationToken cancellationToken = default);
```

Every consumer (ACME issuer, DNS provider, SSH deployer) resolves secrets through it, and no
secret value is persisted or logged. To adopt Vault/AWS KMS/Azure Key Vault/GCP KMS:

1. Implement `ISecretResolver` for the chosen provider, parsing a new reference scheme
   (e.g. `secret://vault/path#field`).
2. Register it in `Program.cs` in place of `EnvironmentSecretResolver` (a single DI line).
3. Migrate the stored references (`managed_services.ssh_credential_ref`, ACME/DNS option
   refs) to the new scheme. References are opaque strings, so no schema change is needed.

For KMS-backed *usage* (not just retrieval) of the ACME account key, the ACME client library
would need a signer callback instead of a PEM string; that is a larger change to
`SmallstepCertificateIssuer` and is only worth it if the account key must never be exported.
Retrieval-time protection (Vault transit/KMS decrypt on resolve) is the pragmatic first step.

**Recommendation:** adopt a vault-backed `ISecretResolver` first (low effort, high value,
no schema change); pursue HSM-backed step-ca signing next; defer non-exportable ACME account
signing unless compliance requires it.

## 2. step-ca high availability

### 2.1 The constraint

The lab/default step-ca uses the **nosql (badger)** backend, which is a single-writer
embedded store. You cannot run two active step-ca instances against one badger volume.

### 2.2 Options

- **Active/passive with shared storage.** Run one step-ca at a time; a failover controller
  (e.g. a leader-elected sidecar) starts the passive instance on the same volume after the
  active fails. Simple, preserves the nosql backend, but failover is not seamless and the
  volume must be on shared/replicated storage.
- **SQL backend (recommended for HA).** step-ca supports PostgreSQL/MySQL backends, allowing
  multiple active step-ca instances behind a load balancer sharing one database. This is the
  clean horizontal-scale path.
  - **Caveat:** the orderIDs corruption patch ([OPERATIONS.md](OPERATIONS.md) §2.1) is
    specific to the **nosql** backend (`acme/db/nosql/order.go`). On a SQL backend the defect
    may not exist (different code path) — **re-verify** order listing/creation under load
    before relying on it, and drop the nosql patch if it does not apply.
- **Managed CA.** Offload issuance to a managed ACME CA if acceptable; removes CA HA from
  your operational surface entirely.

### 2.3 Interaction with TrustForge

TrustForge's issuer reconciles orders by listing the account's orders and reusing the newest
matching unexpired `pending`/`ready` order. With multiple active CAs sharing a SQL backend,
this reconciliation remains correct (orders are shared state). Ensure all CA instances share
the same root/intermediate and provisioner config so any instance can validate and finalize.

**Recommendation:** move step-ca to a SQL backend for HA, re-verify the order-index behavior,
and keep the root offline/HSM-backed.

## 3. Multi-instance TrustForge

### 3.1 Already safe for multiple instances

The job-processing core is designed for concurrent workers and is safe to scale out:

- **Claiming:** `FOR UPDATE SKIP LOCKED` in `TryClaimNextAsync` lets many workers claim
  distinct jobs without contention.
- **Fencing:** a renewable lease token fences every state/checkpoint write
  (`TryUpdateLeasedAsync`, `TryUpdateCheckpointLeasedAsync`, deployment-version writes); a
  worker that lost its lease cannot rewrite history.
- **Concurrency guard:** the partial unique index `ux_certificate_jobs_active_service`
  enforces one active job per service at the database level across all instances.
- **Idempotency:** stable `jobId` correlation keys, fingerprint-keyed renewal jobs, and
  forward-only deployment writes make stage replays idempotent.
- **Alerts:** the delivery worker claims due alerts with `FOR UPDATE SKIP LOCKED` and a
  visibility timeout; multiple instances deliver at least once without double-claiming.
- **Renewal/expiry schedulers:** the renewal minimum-interval + fingerprint idempotency and
  the expiry `dedupe_key` unique index prevent duplicate jobs/alerts even if several
  instances scan simultaneously.

### 3.2 Blockers to resolve before scaling out

| Blocker | Why | Resolution |
| --- | --- | --- |
| **Embedded Technitium DNS per instance** | Each TrustForge process runs its own DNS engine and `dns-config` volume. N instances = N independent DNS servers; DNS-01 TXT records written by one instance are not visible to the others or to step-ca unless they share zone state. | Externalize DNS: run a single shared Technitium (or any RFC 2136 DNS) and point `TechnitiumDns:BaseUrl` at it, disabling the embedded engine (`DnsServer:Enabled=false`) on API/worker instances. The `IDnsChallengeProvider` seam already targets a remote API. |
| **Local artifacts volume** | `FileCertificateArtifactStore` writes to a local directory. Multiple instances need the same bundles readable/writable. | Use a shared RWX volume, or implement `ICertificateArtifactStore` over object storage (S3/Azure Blob/GCS). The interface is already abstracted. |
| **Concurrent `--migrate` on startup** | Every container runs migrations at boot; simultaneous starts can race. | Run migrations as a single pre-deploy job/step (or an advisory-lock-guarded migrator) and start API/worker instances with migration disabled. |
| **Embedded DNS admin/UI coupling** | The DNS UI and admin auth live in-process today. | Follows from externalizing DNS; manage the shared DNS server separately. |

### 3.3 Recommended target topology

- Stateless TrustForge API+worker replicas (embedded DNS disabled), sharing PostgreSQL and a
  shared artifact store, behind a load balancer.
- A single shared DNS service (Technitium or equivalent) for DNS-01.
- step-ca on a SQL backend, multiple active instances, root offline/HSM.
- Migrations applied by a dedicated pre-deploy step.
- Secrets via a vault-backed `ISecretResolver`.

## 4. Adoption matrix

| Capability | Effort | Value | Dependencies | Suggested order |
| --- | --- | --- | --- | --- |
| Vault/KMS-backed `ISecretResolver` | Low | High | none (DI seam exists) | 1 |
| step-ca root offline + intermediate HSM/KMS | Medium | High | step-ca config | 2 |
| step-ca SQL backend + HA (re-verify orderIDs) | Medium | High | shared DB | 3 |
| Externalize DNS (shared Technitium) | Medium | High (unblocks scale-out) | `IDnsChallengeProvider` remote | 4 |
| Shared/object-store artifacts | Low–Medium | Medium | `ICertificateArtifactStore` impl | 4 |
| Single pre-deploy migration step | Low | Medium | deployment pipeline | 4 |
| Multi-instance API+worker scale-out | Medium | High | items 4 above | 5 |
| Non-exportable ACME account signing (KMS signer) | High | Compliance-only | ACME client signer callback | defer |

The through-line: TrustForge's durable, fenced, idempotent job core is already
multi-instance-ready; the remaining work is externalizing the two stateful sidecars (DNS and
artifacts), hardening the CA, and centralizing secret access and migrations.