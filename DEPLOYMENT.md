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

step-ca must resolve the challenge names through this Technitium instance (point the CA's system resolver at it). Each managed Linux target needs the root-owned `trustforge-certctl` helper, root-managed service/action registrations and a dedicated SSH account restricted to that helper; see [remote-helper/README.md](remote-helper/README.md). Issued public certificate material is stored in the `trustforge-certificate-artifacts` volume; private keys are generated and remain on the targets.

For an isolated end-to-end rehearsal of this configuration, use the disposable lab in [dev/acme-lab/README.md](dev/acme-lab/README.md).

## Open the project

Open `TrustForge.sln` in Visual Studio or `dotnet build TrustForge.sln`. This solution contains TrustForge and the Linux-compatible DNS engine/projects. The Windows service and system tray launchers are not part of TrustForge's supported deployment.
