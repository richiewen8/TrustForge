# Certificate issuance and deployment pipeline

This document defines the durable stage protocol used by the PostgreSQL Worker. A job state identifies the next unit to execute. The processor performs at most one state unit per claim, persists any recovery checkpoint with the live lease token, and then appends exactly one state transition. A reclaimed job resumes from its persisted state and checkpoint.

## Stage protocol

| Current state | Work performed | Durable result / next state |
| --- | --- | --- |
| `Queued` | Start the pipeline without external side effects. | `Connecting` |
| `Connecting` | SSH host-key pin validation and remote helper protocol negotiation. | `GeneratingCsr` |
| `GeneratingCsr` | Generate the service private key on the Linux target and return only its CSR. | Save CSR PEM; `CreatingOrder` |
| `CreatingOrder` | Create or recover the ACME order using the stable job ID and saved order URL. | Save order URL; `AwaitingChallenge` |
| `AwaitingChallenge` | Obtain the DNS-01 challenge, add the exact TXT value, wait for DNS and ACME authorization, then remove only that job's TXT value. | Save authorization/record references; `Signing` |
| `Signing` | Finalize the order with the CSR, download and validate the certificate and chain. | Save an artifact-store reference and fingerprint; `Staging` |
| `Staging` | Upload certificate and chain to a unique remote release directory; never upload a private key. | Save release ID; `Activating` |
| `Activating` | Ask the fixed remote helper to atomically switch the active release and run the allow-listed reload action. | Save previous release ID; `Verifying` |
| `Verifying` | Check health and the certificate fingerprint actually served by the target. | `Succeeded`, or perform rollback and end in `FailedRolledBack` / `RollbackFailed` |

The simulator walks this state graph without making network calls, creating files, issuing a certificate, or claiming deployment success. It ends in the distinct terminal `Simulated` state.

## Recovery and checkpoint rules

- Checkpoint JSON is versioned with the job row and may contain only non-secret workflow references: CSR PEM, ACME order/authorization URLs, DNS record name/value, certificate artifact reference, and deployment release IDs.
- Never persist a private key, SSH credential, ACME account key, DNS bearer token, or raw issued bundle in the job checkpoint. The private key is generated and retained on the Linux target. Issued public certificate material belongs in the future protected artifact store.
- Every external mutation uses `jobId` as its idempotency/correlation key. A resumed step first checks the target system for the already-created resource before creating another one. ACME does not provide generic request idempotency; its adapter must save the order URL immediately and reconcile the account's existing orders if the process dies between order creation and checkpoint persistence.
- DNS cleanup removes only the TXT record matching both the challenge owner name and value. Failure and lease-expiry recovery must retry cleanup before leaving the challenge stage.
- SSH verifies the configured OpenSSH SHA-256 host-key fingerprint before any command or upload. Commands are fixed helper operations selected by registered IDs; no user-controlled shell fragments or paths are accepted.
- A lease token fences all state/checkpoint writes. It cannot make an external side effect exactly once; adapters must reconcile after crash, and must stop if the lease is lost.
- Activation and health-check errors must report whether remote rollback succeeded. A lost SSH connection during activation is an ambiguous outcome and requires querying the helper's current release before retrying.

## Adapter contracts

`ICertificateIssuer` owns ACME order/authorization/finalization; `IDnsChallengeProvider` owns narrowly-scoped DNS-01 record create/propagation/cleanup; `ILinuxCertificateDeployer` owns pinned SSH, target-side CSR generation, staged deployment, activation, health/fingerprint verification, and rollback. These interfaces pass stable job IDs and persisted references so their implementations can be retried after a process restart.

The development simulation is opted in only when `ASPNETCORE_ENVIRONMENT=Development` and `CertificateJobs:Simulation:Enabled=true` (Compose: `TRUSTFORGE_SIMULATION_ENABLED=true`). It automatically enables the Worker and cannot be enabled in Production. Real adapter registration remains a separate mode; the simulator must never coexist with production adapters.
