# TrustForge Linux deployment

TrustForge is deployed as one application container. The DNS engine runs inside the TrustForge process; it is not a separate Technitium container. PostgreSQL runs as the application's persistence dependency in the same Compose stack. Configure an external HTTPS OIDC issuer for API authentication.

## Requirements

- Docker Engine with the Compose plugin on Linux.
- This checkout and the sibling `TechnitiumLibrary` source directory under the same parent folder. The image is built from that parent context.
- A reachable HTTPS OIDC issuer and its TrustForge API audience.
- TCP and UDP port 53 available on the host.

## Start

Copy `.env.trustforge.example` to `.env`, set a unique `POSTGRES_PASSWORD`, and set the OIDC authority and audience. From the TrustForge repository directory, run:

```sh
docker compose up -d --build
```

The container applies checked-in PostgreSQL migrations before starting the API and embedded DNS engine. Compose persists PostgreSQL data, DNS configuration, and DNS logs in named volumes.

## Endpoints

- TrustForge API: `http://<host>:5000`, normally placed behind an HTTPS reverse proxy.
- DNS service: host TCP/UDP port `53` by default. Set `TRUSTFORGE_DNS_PORT` when the host requires a different port.
- Technitium DNS administration UI: `http://127.0.0.1:5380` by default. Use an SSH tunnel or set `TRUSTFORGE_DNS_UI_BIND` to an explicitly trusted management interface.
- PostgreSQL is reachable only on the Compose network; its port is not published on the host.

The DNS administration UI retains its own Technitium authentication settings. TrustForge API OIDC/RBAC currently governs TrustForge APIs; a unified login and UI are planned separately.

## Certificate issuance (Smallstep ACME + DNS-01)

The certificate worker is disabled by default. To run the real issuance/deployment pipeline, set `TRUSTFORGE_WORKER_ENABLED=true` and configure:

- `TRUSTFORGE_ACME_DIRECTORY_URL`: the step-ca ACME directory, e.g. `https://ca.internal.example/acme/trustforge/directory`. The URL must be HTTPS and its certificate must validate against the configured root.
- `TRUSTFORGE_ACME_ROOT_CERT_PATH`: path (inside the container) to the step-ca root certificate PEM. Required: issued certificates are validated against this root before deployment. Mount it read-only from your secret/certificate distribution channel.
- `TRUSTFORGE_ACME_ACCOUNT_EMAIL` and `TRUSTFORGE_ACME_ACCOUNT_KEY_REF`: the ACME account contact and a secret reference (`secret://env/NAME`, or `secret://file/` followed by an absolute path, e.g. `secret://file//run/trustforge/secrets/acme-account.pem` — note the double slash) to the account private key PEM. Generate a dedicated EC P-256 key in PKCS#8 PEM (`BEGIN PRIVATE KEY`, e.g. `openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256`); never reuse a target service key. If your provisioner requires External Account Binding, set `TRUSTFORGE_ACME_EAB_KEY_ID` and `TRUSTFORGE_ACME_EAB_KEY_REF` together.
- `TRUSTFORGE_TECHNITIUM_API_URL` and `TRUSTFORGE_TECHNITIUM_API_TOKEN_REF`: the embedded DNS API (loopback HTTP is allowed) and a secret reference to a least-privilege API token. Create a dedicated DNS user with View/Modify/Delete permission on the challenge zones only — no global administration rights.
- `TRUSTFORGE_DNS_CHALLENGE_ZONE_0`: the zone allowed for `_acme-challenge` records. Challenges outside the configured zones are rejected.
- `TRUSTFORGE_DNS_CHALLENGE_RESOLVER_ADDRESS`/`_PORT`: the resolver used to confirm TXT propagation before ACME validation; normally the embedded server itself.

The worker wakes on a transactional PostgreSQL `NOTIFY` sent in the same transaction as each job insert; `TRUSTFORGE_WORKER_NOTIFICATION_ENABLED` (default `true`) controls this, with `TRUSTFORGE_WORKER_POLL_INTERVAL` polling as the loss-safe fallback. The durable job row is the queue, so a missed notification only adds latency, never loses a job. See [CERTIFICATE-PIPELINE.md](CERTIFICATE-PIPELINE.md).

step-ca must resolve the challenge names through this Technitium instance (point the CA's system resolver at it). Each managed Linux target needs the root-owned `trustforge-certctl` helper, root-managed service/action registrations and a dedicated SSH account restricted to that helper; see [remote-helper/README.md](remote-helper/README.md). Issued public certificate material is stored in the `trustforge-certificate-artifacts` volume; private keys are generated and remain on the targets.

### Secret files, revocation and CRL distribution

`secret://file//run/trustforge/secrets/<name>` references resolve **inside the container**, so the
directory `TRUSTFORGE_SECRETS_DIR` (default `./secrets`) is bind-mounted read-only at
`/run/trustforge/secrets`. Put there: the ACME account key PEM, `SmallstepAcme:RootCertificatePath`,
the Technitium API token, and one `{"username","privateKeyPem"}` JSON per managed service (the path
goes in that service's `sshCredentialRef`). Read-only is deliberate — the API writes keys to targets
and never to its own secret store. Volumes persist container recreation, so deleting the stack with
`down -v` destroys them; see [OPERATIONS.md](OPERATIONS.md) section 3.

Revocation is a separate durable worker: `TRUSTFORGE_REVOCATION_ENABLED` (default `true`),
`TRUSTFORGE_REVOCATION_POLL_INTERVAL`, `TRUSTFORGE_REVOCATION_VISIBILITY_TIMEOUT` and
`TRUSTFORGE_REVOCATION_MAX_ATTEMPTS`. A `POST /api/v1/services/{id}/revocations` (role
`PlatformAdmin` only) records the request and the worker delivers it to the CA; if the worker is
disabled, or the container has no account key, the record stays `Pending` forever — a revocation that
was requested is not a revocation that happened. Set `TRUSTFORGE_RETAINED_RELEASES` for how many
releases each target keeps after a verified deployment.

Publishing the result is the CA's job: step-ca serves a CRL only when its provisioner JSON enables
the `crl` block, and a revoked serial appears promptly only with `generateOnRevoke`. Verify the
endpoint that relying parties will actually use — `curl --cacert <root> <crl url> | openssl crl
-inform DER -noout -text` — and confirm your serial is listed after revoking. Measured timings and
the CA-side knobs are in [OPERATIONS.md](OPERATIONS.md) section 2.6; `dev/acceptance/` asserts all of
it against a real CA before you rely on it.

For an isolated end-to-end rehearsal of this configuration, use the disposable lab in [dev/acme-lab/README.md](dev/acme-lab/README.md).

For day-two operations — backup/restore, key rotation, schema upgrades, disaster recovery and monitoring — see [OPERATIONS.md](OPERATIONS.md). For production hardening options (HSM/KMS, step-ca high availability, multi-instance TrustForge) see [HSM-KMS-HA-EVALUATION.md](HSM-KMS-HA-EVALUATION.md).

## Open the project

Open `TrustForge.sln` in Visual Studio or `dotnet build TrustForge.sln`. This solution contains TrustForge and the Linux-compatible DNS engine/projects. The Windows service and system tray launchers are not part of TrustForge's supported deployment.
