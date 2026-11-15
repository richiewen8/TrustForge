# TrustForge ACME development lab

An isolated, fully containerized lab that exercises the real certificate pipeline end to end:
TrustForge (API + embedded Technitium DNS + worker) issues a certificate through Smallstep
`step-ca` over ACME DNS-01 and deploys it to a Linux target over pinned SSH. No simulation is
involved; the worker runs the production `CertificatePipelineProcessor` in Development mode.

## Topology

- `trustforge` — the product image built from the root `Dockerfile` (static IP `.10`).
- `keycloak` — shares the app network namespace so `http://localhost:8280` is a loopback
  issuer for both the API and host-side scripts (`Authentication__AllowInsecureLoopback`).
- `postgres` — job/service persistence.
- `step-ca` — ACME CA (static IP `.20`), initialized on first run with an `acme` provisioner.
  Its DNS points at the embedded Technitium server so DNS-01 validation resolves the
  `_acme-challenge` records.
- `target` — Debian SSH host (static IP `.30`) with the root-owned `trustforge-certctl`
  helper, a dedicated `trustforge-deployer` account and a demo TLS service on port 8443.

Port 53 is never published to the host. The subnet defaults to `172.30.90.0/24`; change
`LAB_SUBNET_PREFIX` in `.env` if it collides with a host or VPN network.

## Usage

Requires Docker Desktop (Linux containers), Git Bash, `curl`, `openssl`, `ssh-keygen` and
`python` on the host.

```sh
cd dev/acme-lab
./setup.sh     # first run creates .env; fill in the passwords and re-run
./verify.sh    # asserts the Phase 4 completion conditions
```

`setup.sh` builds the images, initializes the CA, extracts the root certificate, generates
the ACME account key and the deployer SSH key, creates the `trustforge.lab` zone with a
least-privilege API token, registers two services and starts one job per service:

- `svc1.trustforge.lab` — expected to reach `Succeeded` and serve the issued certificate.
- `svc2.not-allowed.example` — outside the configured zone allowlist; expected to reach
  `Failed` at `AwaitingChallenge` without leaving any TXT record behind.

Generated secrets live in `secrets/` (gitignored): CA root, ACME account key, DNS API token,
SSH key pair and credential JSON. Treat the lab as disposable; `docker compose down -v`
resets all persistent state.

## Notes

- step-ca defaults to 24-hour certificate and order lifetimes; lab certificates expire
  daily. Automatic renewal is a later phase.
- The demo health action exits successfully while no certificate is installed, because the
  pipeline's `Connecting` stage runs the health check before the first deployment.
- Recovery can be drilled manually: stop the app while a job is `AwaitingChallenge`
  (`docker compose stop trustforge`), start it again, and watch the job resume after the
  lease expires and still reach `Succeeded`.