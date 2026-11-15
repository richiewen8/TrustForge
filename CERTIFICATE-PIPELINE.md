# Certificate issuance and deployment pipeline

This document defines the durable stage protocol used by the PostgreSQL Worker. A job state identifies the next unit to execute. The processor performs at most one state unit per claim, persists any recovery checkpoint with the live lease token, and then appends exactly one state transition. A reclaimed job resumes from its persisted state and checkpoint.

## Stage protocol

| Current state | Work performed | Durable result / next state |
| --- | --- | --- |
| `Queued` | Start the pipeline without external side effects. | `Connecting` |
| `Connecting` | SSH host-key pin validation and remote helper health/protocol check. | `GeneratingCsr` |
| `GeneratingCsr` | Generate the service private key on the Linux target and return only its CSR. | Save CSR PEM; `CreatingOrder` |
| `CreatingOrder` | Create or recover the ACME order using the stable job ID and saved order URL. | Save order URL; `AwaitingChallenge` |
| `AwaitingChallenge` | Obtain DNS-01 challenges, checkpoint them, add exact TXT values through Technitium, wait for DNS and ACME authorization, then remove each job-owned value even after a failure. | `Signing` |
| `Signing` | Finalize the order with the CSR, download the public certificate bundle, and validate it against the CA root and the service registration. | Save bundle in the persistent artifact volume, record its reference and fingerprint; `Staging` |
| `Staging` | Send public certificate material to the fixed remote helper. The target combines it with the private key it generated earlier. | Save release ID; `Activating` |
| `Activating` | Ask the fixed remote helper to atomically switch the current symlink, run the allow-listed reload action, and return the previous release ID. | Save previous release ID; `Verifying` |
| `Verifying` | Check the active certificate fingerprint and run the registered health action. | `Succeeded`, or perform rollback and end in `FailedRolledBack` / `RollbackFailed` |

The simulator walks this state graph without making network calls, creating files, issuing a certificate, or claiming deployment success. It ends in the distinct terminal `Simulated` state.

## Recovery and checkpoint rules

- Checkpoint JSON is versioned with the job row and may contain only non-secret workflow references: CSR PEM, ACME order URL, certificate artifact reference, and deployment release IDs.
- Never persist a private key, SSH credential, ACME account key, DNS bearer token, or raw issued bundle in the job checkpoint. The private key is generated and retained on the Linux target. Issued public certificate material is kept in the persistent `trustforge-certificate-artifacts` volume.
- Every external mutation uses `jobId` as its idempotency/correlation key. A resumed step first checks the target system for the already-created resource before creating another one. ACME does not provide generic request idempotency; its adapter must save the order URL immediately and reconcile the account's existing orders if the process dies between order creation and checkpoint persistence.
- DNS cleanup removes only the TXT record matching both the challenge owner name and value. Challenges are checkpointed before the first record is presented and cleared after successful cleanup, so failure and lease-expiry recovery always knows exactly which records to remove. A resumed challenge stage reuses the checkpointed challenges; when every ACME authorization is already valid the stage advances without new DNS work.
- SSH verifies the configured OpenSSH SHA-256 host-key fingerprint before any command or upload. Commands are fixed helper operations selected by registered IDs; no user-controlled shell fragments or paths are accepted.
- A lease token fences all state/checkpoint writes. It cannot make an external side effect exactly once; adapters must reconcile after crash, and must stop if the lease is lost.
- The remote helper persists the previous symlink target before activation; repeating activation for the same job preserves that target. Activation and health-check errors trigger rollback and end in `FailedRolledBack` or `RollbackFailed`.

## Adapter contracts

`ICertificateIssuer` owns ACME order/authorization/finalization; `IDnsChallengeProvider` owns narrowly-scoped DNS-01 record create/propagation/cleanup; `ILinuxCertificateDeployer` owns pinned SSH, target-side CSR generation, staged deployment, activation, health/fingerprint verification, and rollback. These interfaces pass stable job IDs and persisted references so their implementations can be retried after a process restart.

The development simulation is opted in only when `ASPNETCORE_ENVIRONMENT=Development` and `CertificateJobs:Simulation:Enabled=true` (Compose: `TRUSTFORGE_SIMULATION_ENABLED=true`). It automatically enables the Worker and cannot be enabled in Production. Set `CertificateJobs:Worker:Enabled=true` for real execution; install the Linux helper and service/action registrations using [remote-helper/README.md](remote-helper/README.md), configure Smallstep ACME and Technitium DNS, and mount the artifact volume persistently.

The ACME order URL is checkpointed immediately after creation. When no order URL is checkpointed, the issuer reconciles the account's existing orders before creating a new one: it lists them with a signed POST-as-GET request (step-ca returns a bare JSON array; RFC 8555 servers wrap it in an `orders` property) and reuses the newest unexpired `pending`/`ready` order whose identifiers exactly match the approved service SANs. Orders already `processing` or `valid` are never reused because their certificate was finalized against a different CSR. Persisted and newly created orders pass the same exact-identifier check. There is no per-service mutex yet (a later phase), so two concurrent jobs for the same SAN set can reconcile to one order; the signing stage's CSR-to-certificate public-key check rejects the losing job before anything is deployed.

Before an issued bundle is persisted or deployed, the signing stage validates it: the chain must build against the configured Smallstep root, the leaf fingerprint must match the signing result, the certificate public key must equal the target-generated CSR's public key, SANs must exactly equal the registered service SANs, EKU must permit server authentication, the key must be RSA ≥ 3072 or ECDSA nistP256/384/521, and the validity window must be current and within `SmallstepAcme:MaximumCertificateLifetime`. The CSR itself is validated for SANs and key strength when it is first collected.
