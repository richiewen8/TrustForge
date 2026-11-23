# Acceptance drill harness (OPERATIONS.md §7)

Runs the §7 procedure set against a **real CA and real targets**: one DNS-01 issuance per host, the
deployment verified through the API *and* against what the target is actually serving, then
revocation of only the certificate the drill minted, confirmed on the CA's CRL.

Nothing here is a substitute for `dev/acme-lab`, which rehearses the same path on disposable
containers. This directory is where that rehearsal is repeated on the infrastructure that matters.

| File | Purpose |
| --- | --- |
| `preflight.sh` | read-only validation of every external input, before an ACME order exists |
| `drill.sh` | the drill itself: register → issue → verify → revoke → CRL → recovery |
| `tlsfetch.py` | TLS fetch pinned to one root CA (CA directory, CRL, served-certificate peek) |
| `dnsprobe.py` | raw DNS query, so the resolver the pipeline polls can be checked directly |
| `acceptance.env.example` | operator intake template → copy to `acceptance.env` (gitignored) |
| `hosts.example.json` | inventory template → copy to `hosts.json` (gitignored) |
| `lab.env`, `lab-hosts.json`, `lab-install.sh` | self-test of this harness against the running `dev/acme-lab` stack; `lab.env` holds the lab operator password and is gitignored, the other two are committed |
| `out/` | per-run reports and target registration JSON (gitignored) |

## Running it

```bash
cd dev/acceptance
cp acceptance.env.example acceptance.env && cp hosts.example.json hosts.json
# fill acceptance.env, write hosts.json, put keys/tokens under secrets/ (all gitignored)
bash preflight.sh          # must end with 0 FAIL
bash drill.sh              # creates real orders on the CA
```

`ACCEPTANCE_ENV=other.env bash preflight.sh` selects a different configuration file.

Run `preflight.sh` first because a real CA charges rate-limit budget per failed order, and most
failure modes it catches (wrong root, unreadable zone, missing `revokeCert`, wrong role, mismatched
host key) only become visible mid-order otherwise.

## Order of operations, and why it cannot be reordered

`POST /api/v1/services` mints the service GUID, and the target helper reads
`/etc/trustforge/services/<GUID without dashes>.json`. The target-side file therefore cannot exist
before the API has answered. `drill.sh` registers the service, prints the GUID and writes the exact
JSON to `out/<name>-<stamp>.registration.json`, then waits for that file to be installed:

- interactive: press Enter once you installed it as root, mode `0600`;
- unattended: set `TF_TARGET_READY_HOOK=./your-installer.sh`, called as
  `HOOK NAME SERVICE_ID REGISTRATION_JSON_PATH TARGET_PATH` (`lab-install.sh` is a worked example).

Either way the write stays an operator-side act: the API is never given that path, and no secret
material travels through it.

## Prerequisites

**On each target** (all enforced by `remote-helper/trustforge-certctl` itself, not by convention):

- helper installed at `/usr/local/sbin/trustforge-certctl`, root-owned, not group/world writable;
  the API runs only `sudo -n /usr/local/sbin/trustforge-certctl` with JSON on stdin, so sudoers must
  allow exactly that command;
- `/etc/trustforge/actions.json`: action id → argv array, `{service_id}` substituted. `validate`
  **executes the registered health action**, so `connection-test` legitimately fails until the
  service really serves TLS on those paths;
- `certificatePath`, `chainPath`, `privateKeyPath`: absolute, traversal-free, distinct filenames, all
  three inside one directory that must be a **symlink** (the helper refuses a real directory because
  activation is an atomic link swap) and must not exist before the first issuance;
- `/var/lib/trustforge/{jobs,releases,state}` on the target filesystem;
- the SSH account's public key in `authorized_keys`, and the target's ED25519 host key fingerprint in
  the inventory — the API pins it, `preflight.sh` compares it against `ssh-keyscan`.

**On the control plane**: worker enabled (`TRUSTFORGE_WORKER_ENABLED=true`), `SmallstepAcme:*`
(`DirectoryUrl`, `AccountKeySecretRef`, `AccountEmail`, and `RootCertificatePath` — issued chains are
verified against that root before anything is persisted), `TechnitiumDns:*` (`BaseUrl`,
`ApiTokenSecretRef`, `AllowedZones`, `ResolverAddress`/`ResolverPort`), and the secret files mounted
where the `secret://file//...` references say. Revocation additionally requires the revocation worker
(`CertificateJobs:Revocation:Enabled`) and a published CRL to be asserted.

**Identities**: the operator token needs `CertificateOperator` (register, issue), `CertificateReader`
(read back) and `PlatformAdmin` — the latter is what `CertificateRevoker` resolves to, and no other
role can revoke.

**Networks**: the *API container* must reach the CA directory, the Technitium API, the resolver
`step-ca` queries, and each target's SSH port. `preflight.sh` proves the *workstation* reaches the
same things, which is not the same test. Where the two differ, `TF_CA_RESOLVE_IP` and the inventory's
`probeSsh`/`tlsProbe` give the operator-side address, and `TF_DNS_RESOLVER_PROBE=skip` suppresses only
the resolver query (the pipeline's own polling still decides issuance). In the lab, for example,
`172.30.90.10:53` is routable from the API network but not from Windows.

**DNS**: the Technitium token needs View/Modify/Delete on the challenge zone and nothing else; a
zone-less permission set fails `records/get`, which is the exact call the pipeline uses.

**CA**: `revokeCert` must appear in the ACME directory, and `TF_CRL_URL` must be served. step-ca only
serves `/1.0/crl` when its provisioner JSON has a `crl` block, and a revoked serial appears promptly
only with `generateOnRevoke: true` — otherwise publication waits for the next scheduled renewal and
`TF_CRL_PROPAGATION_SECONDS` must be raised accordingly.

## TLS and key policy

No check in this directory relaxes verification. `tlsfetch.py` pins one root CA and still matches the
URL hostname; `--override-ip` changes only the address it opens, so SNI, name matching and the trust
anchor are untouched. `curl` is not used for CA, CRL or peer-certificate probes: Windows curl builds
use schannel, which applies a system revocation policy to a private CA and reports *"the revocation
status is unknown"* for a certificate that verifies fine here.

Private keys are generated on the target and never leave it; the drill reads only public material
(the served leaf, its serial and fingerprint).

## Reading the result

`drill.sh` writes `out/acceptance-<stamp>.json` (service id, job id, fingerprint, serial per host) and
ends with `N PASS / M FAIL of K checks`, exiting non-zero on any failure. Per host it asserts: helper
validation through `connection-test`, an issued fingerprint, `Active` + `Healthy` deployment history,
the served certificate verifying against the CA root *and* being the one the job issued, the
revocation record `Revoked` without a CA error, an idempotent replay that did not re-call the CA, the
serial present on the CRL, and — with `TF_REISSUE_AFTER_REVOKE=true` — that a fresh job mints a
different certificate.

Knobs: `TF_REVOKE_AFTER=false` stops after issuance (nothing is revoked), `TF_REVOCATION_REASON`
takes any RFC 5280 reason the API accepts, `TF_JOB_TIMEOUT_SECONDS`, `TF_REVOCATION_TIMEOUT_SECONDS`
and `TF_CRL_PROPAGATION_SECONDS` bound the waits.

## Self-test against `dev/acme-lab`

With the lab stack up (`dev/acme-lab/setup.sh`), `ACCEPTANCE_ENV=lab.env bash preflight.sh` reports
`42 PASS / 0 FAIL of 42 checks` and `ACCEPTANCE_ENV=lab.env bash drill.sh` reports
`12 PASS / 0 FAIL of 12 checks` against a real step-ca, a real Technitium server and a real SSH target.
`lab.env` sets `TF_REISSUE_AFTER_REVOKE=true` so the target is left with a valid certificate and
`dev/acme-lab/verify.sh` stays green afterwards.
