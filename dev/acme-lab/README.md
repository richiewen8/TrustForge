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
  `_acme-challenge` records. Built from `step-ca/Dockerfile`: the official image plus a
  one-line fix for an upstream bug (see Notes).
- `target` — Debian SSH host (static IP `.30`) with the root-owned `trustforge-certctl`
  helper, a dedicated `trustforge-deployer` account and a demo TLS service on port 8443.

Port 53 is never published to the host. The subnet defaults to `172.30.90.0/24`; change
`LAB_SUBNET_PREFIX` in `.env` if it collides with a host or VPN network.

## Usage

Requires Docker Desktop (Linux containers), Git Bash, `curl`, `openssl`, `ssh-keygen` and
`python` on the host. `drill-migration.sh` additionally needs the .NET SDK and the
`dotnet ef` tool on the host to generate the baseline schema offline; every other drill
runs entirely inside containers.

```sh
cd dev/acme-lab
./setup.sh              # first run creates .env; fill in the passwords and re-run
./drill-deployment.sh   # Phase 5 drills: rollback, rollback failure, retention pruning
./drill-backup.sh       # Phase 6 drill: back up PostgreSQL, CA/DNS/artifact volumes, target state
./drill-restore.sh      # Phase 6 drill: destroy the lab and restore it from the backup
./drill-notification.sh # Phase 3 drill: LISTEN/NOTIFY transactional wake A/B vs polling
./drill-migration.sh    # Phase 1 drill: real old-schema → new-schema upgrade on seeded data
./drill-renewal.sh      # Phase 6 drills: concurrency guard, automatic renewal
./drill-revocation.sh   # Phase 7 drills: CRL precondition, RBAC, real ACME revocation, retry
./verify.sh             # asserts the Phase 4/5/6/7 completion conditions
```

Run the drills in this order. Backup/restore runs **before** `drill-renewal.sh` so the
renewal-enabled service is registered fresh after the restore. `drill-notification.sh` also
runs **before** `drill-renewal.sh`: it recreates the app with a 30s poll interval for the A/B
measurement and restores the base config when it finishes, leaving Keycloak ready.
`verify.sh` needs no adjacency to the drills any more: the renewal-enabled service keeps renewing
every 2 minutes for the rest of the lab's life and can win the shared deployment path at any
moment, so `verify.sh` resolves the *current* release from the target (`releases/<service>/<job>`)
and derives its renewal and fingerprint assertions from live state instead of assuming the last
recorded job still owns the path. It asserts the rate guarantees (renewals at least
`MinimumRenewalInterval` apart, no fingerprint renewed twice) rather than a wall-clock-lucky
"exactly one renewal exists".
Running notification before renewal also puts its `notificationDrill` result in
`lab-state.json` before `verify.sh`, so the notification section is exercised.
`drill-migration.sh` runs **before** `drill-renewal.sh` as well: it upgrades disposable side
databases (`trustforge_upgrade` / `trustforge_upgrade_bad`) through a one-off `--migrate`
container, never recreating the app or touching the main lab database, so it leaves the
renewal → verify window intact and puts its `migrationDrill` result in `lab-state.json` for
`verify.sh`. `drill-revocation.sh` runs **after** `drill-renewal.sh` — it needs a lab with a
deployed, currently-served certificate to revoke — and it ends by handing the shared
`/etc/trustforge-demo/current` symlink back to a fresh `svc1` deployment, because its own serial
assertions read that path and a renewal-enabled service may otherwise replace it mid-drill.
`verify.sh` itself no longer depends on the ordering: it derives the deployed certificate from
whichever release owns the path (see above).

`setup.sh` builds the images, initializes the CA, extracts the root certificate, generates
the ACME account key and the deployer SSH key, creates the `trustforge.lab` zone with a
least-privilege API token, registers two services and starts one job per service:

- `svc1.trustforge.lab` — expected to reach `Succeeded` and serve the issued certificate.
- `svc2.not-allowed.example` — outside the configured zone allowlist; expected to reach
  `Failed` at `AwaitingChallenge` without leaving any TXT record behind.

Generated secrets live in `secrets/` (gitignored): CA root, ACME account key, DNS API token,
SSH key pair and credential JSON. Treat the lab as disposable; `docker compose down -v`
resets all persistent state. After `down -v` also delete `secrets/root_ca.crt` and
`secrets/lab-state.json` so setup re-extracts the new CA root.

`drill-deployment.sh` registers a third service (`svc3.trustforge.lab`) whose health action
honors failure markers, then:

1. arms a one-shot health failure during deployment — the job must roll back and end
   `FailedRolledBack` with a Warning `DeploymentRolledBack` alert;
2. arms a persistent health failure — rollback itself fails and the job must end
   `RollbackFailed` with a Critical `RollbackFailed` alert;
3. runs two more successful `svc1` deployments so the retention policy
   (`CertificateJobs__Deployment__RetainedReleases=2`) prunes the oldest release and its
   job key directory while the active release and rollback slot survive.

The target also runs a lab-only webhook receiver on port 8444 that appends delivered
alerts to `/var/lib/trustforge-demo/alerts.jsonl`; the app delivers alerts to
`http://target:8444/alerts`. `verify.sh` checks deployment version records, alert kinds,
severities and delivery, receiver receipts, active file ownership/permissions, and the
retention outcome.

`drill-renewal.sh` exercises the Phase 6 renewal controls:

1. database-level concurrency guard — it creates one `svc1` job and immediately attempts a
   second active job for the same service; the second must be rejected with HTTP 409
   `service_job_active` (partial unique index `ux_certificate_jobs_active_service`) and never
   persisted;
2. automatic renewal — it registers `svc4.trustforge.lab` with `renewalEnabled=true` and a
   25h `renewalLeadTime` (longer than the 24h lab certificate lifetime, so the active
   certificate is always inside the renewal window), bootstraps it with a manual job, then
   waits for the `RenewalSchedulerWorker` to create exactly one `renewal-scheduler` job. The
   renewal job must succeed, record `certificateNotAfter` on its deployment version, supersede
   the bootstrap version, and not be re-issued on the scans that follow it immediately (the
   `CertificateJobs__Renewal__MinimumRenewalInterval=00:02:00` floor and the fingerprint
   idempotency key `renewal-{fingerprint}` bound the rate). The 25h lead time on 24h
   certificates is deliberate: the service never leaves its renewal window, so the scheduler
   keeps issuing every 2 minutes for the rest of the lab's life. `drill-renewal.sh` therefore
   asserts "exactly one job" only at its own moment, and `verify.sh` asserts the durable
   guarantees — successive renewals at least `MinimumRenewalInterval` apart, no fingerprint
   renewed twice, and the newest renewal's release owning the Active version.

The drill finishes with a fresh `svc1` deployment so `svc1` owns the shared
`/etc/trustforge-demo/current` symlink again before `verify.sh` checks the served certificate.
Renewal scanning is configured with `CertificateJobs__Renewal__ScanInterval=00:00:05` and
`CertificateJobs__Renewal__MinimumRenewalInterval=00:02:00` in `docker-compose.yml`.

## Backup and restore drills

`drill-backup.sh` and `drill-restore.sh` rehearse the disaster-recovery runbook in
[OPERATIONS.md](../../OPERATIONS.md) against the real lab state. They require
`drill-deployment.sh` to have run first.

`drill-backup.sh` quiesces the app, CA and Keycloak, then writes a self-contained backup
under `secrets/backup/` (gitignored):

- `trustforge.dump` — `pg_dump -Fc` of the lab database;
- tarballs of the `lab-stepca-data` (CA config/keys), `lab-artifacts` (issued public
  certificate material) and `lab-dns-config` (Technitium zone/config) named volumes,
  extracted with a helper container (`--entrypoint sh` so the image's service entrypoint
  does not run);
- a tarball of the target's writable layer (`/etc/trustforge`, `/var/lib/trustforge`,
  `/etc/trustforge-demo`, `/var/lib/trustforge-demo`) — releases, helper registrations and
  the demo TLS state;
- a copy of `secrets/` and a `manifest.json` recording the backup job ID, the dump SHA-256
  and the row counts of `managed_services`, `certificate_jobs`, `deployment_versions` and
  `certificate_alerts`.

`drill-restore.sh` then destroys the lab (`docker compose down -v`) and rebuilds it from the
backup: it restores PostgreSQL with `pg_restore`, extracts the volume tarballs **before**
their services first start (step-ca re-initializes a brand-new CA on an empty volume, so the
CA tarball must be in place before `up`), restores the target writable layer using the
**existing** target image (never `--build` — the SSH host keys are baked into the cached
image layer), and brings the app and Keycloak back up. It asserts the restored row counts
equal the manifest, issues a fresh `svc1` job to prove the recovered CA keys still sign, and
records `restoreDrill.backupJobId` / `restoreDrill.postRestoreJobId` in `lab-state.json`.
`verify.sh` checks those jobs reached `Succeeded` and that the manifest exists; without a
`restoreDrill` entry that section is skipped.

Because the backup legitimately contains secrets, `secrets/backup/` is gitignored and the
lab is disposable. After a manual `down -v` outside the restore drill, delete
`secrets/root_ca.crt` and `secrets/acme-account.pem` so `setup.sh` re-extracts the new CA
root and registers a fresh ACME account key.

## Notification (LISTEN/NOTIFY) drill

`drill-notification.sh` proves the Phase 3 transactional wake: a PostgreSQL `NOTIFY` issued
in the job-creation transaction wakes the worker immediately, while polling remains the
loss-safe fallback. It uses only `svc1` (`renewalEnabled=false`) to avoid renewal-scheduler
races.

The measurement is **phase-anchored** so the result is conclusive rather than poll-phase
luck. With `CertificateJobs__Worker__PollInterval=00:00:30` (via the gitignored
`secrets/notification-override.yml`), it creates an anchor job; once the anchor reaches a
terminal state the worker immediately re-claims (nothing queued) and enters a fresh
full-interval wait. After a 2s settle it creates job B, so B's latency is deterministic:

- **Control phase** (`NotificationEnabled=false`): B is poll-bound — asserted **≥ 20s**.
- **Notify phase** (`NotificationEnabled=true`, same 30s interval): NOTIFY wakes the worker
  at once — asserted **< 12s** (typically ~3-4s), and `pg_stat_activity` must show a
  `trustforge-job-listener` connection.

The contrast (tens of seconds vs a few seconds at the same poll interval) attributes the
fast wake to NOTIFY rather than to polling phase. Each phase recreates the app with
`up -d --no-deps --force-recreate trustforge` followed by `up -d keycloak` (recreating the
app invalidates Keycloak's shared netns — never `restart`). The drill restores the base
config afterwards, waits for the API and Keycloak to be ready, and records
`notificationDrill{controlJobId,controlLatencySeconds,notifyJobId,notifyLatencySeconds}` in
`lab-state.json` (updating `jobId` to the notify-phase deployment). `verify.sh` re-checks
those values when the entry is present; without it that section is skipped.

## Migration upgrade drill

`drill-migration.sh` proves the Phase 1 upgrade-strategy condition: a database that already
holds production-like data is upgraded from an **older schema** to the current one through
the real product `--migrate` path, with data preserved and the new invariants enforced. It
is the only drill that needs the .NET SDK and `dotnet ef` on the host (to generate the
baseline schema offline); everything else runs in containers.

It uses two **disposable side databases** (`trustforge_upgrade` and the negative-test
`trustforge_upgrade_bad`) on the lab PostgreSQL — never the main lab database — and a
one-off `--entrypoint dotnet … TrustForge.dll --migrate` container, so it does not recreate
the app, disturb Keycloak's network namespace, or race the renewal scheduler.

1. **Baseline** — `dotnet ef migrations script` generates the full schema offline; the
   script is truncated to the first five migrations (through
   `202611150001_DeploymentVersionsAndAlerts`) and applied to a fresh side database. The
   drill asserts the baseline has exactly 5 history rows and **lacks** `renewal_enabled`
   and the active-job guard, so this is a genuine incremental upgrade, not a fresh install.
   (The EF tools 10.0.14 / runtime 10.0.15 skew makes `migrations script` reject any *named*
   target; the full-script-plus-truncate works around it without changing global tooling.)
2. **Seed** — production-like rows at the baseline schema: 2 services, 5 jobs (Succeeded /
   Failed / Queued, one carrying a PascalCase execution checkpoint), 10 transitions, 3
   deployment versions (Superseded / Active / Staged) and 2 JobFailed alerts. No key
   material is seeded.
3. **Upgrade** — the real `--migrate` path applies every migration after
   `202611150001_DeploymentVersionsAndAlerts`: `202611150002_RenewalAndActiveJobGuard`,
   `202611150003_ExpiryReminders` and `20261123125511_CertificateRevocations`. The expected
   history total is derived from the generated script, so a new migration cannot leave the
   assertion stale. The drill asserts history reaches that total, every seeded
   row count is preserved, existing rows take the new column defaults (`renewal_enabled`
   false, `renewal_lead_time` 0, `certificate_not_after` NULL), the three alert/job indexes and
   the `ck_certificate_alerts_identity` check exist, the alerts `job_id` index is now
   *partial*, the `certificate_revocations` table arrives with its FKs, its due/idempotency
   indexes and a *partial* `ux_certificate_revocations_live_serial` (`WHERE state <> 'Failed'`),
   and the checkpoint JSON survives intact.
4. **Idempotency** — re-running `--migrate` is a no-op (history stays at the derived total,
   jobs stay 5).
5. **New-shape writes** — two expiry-reminder alerts with `job_id NULL` + distinct
   `dedupe_key` are accepted (the partial unique index allows many NULL `job_id`s); a
   duplicate `dedupe_key` is rejected by `ux_certificate_alerts_dedupe_key` and an alert
   with neither identity is rejected by `ck_certificate_alerts_identity`.
6. **Dirty-data rejection** — the negative-test database is seeded with a *second* active
   job for the same service, so `ux_certificate_jobs_active_service` cannot be created.
   `--migrate` must exit non-zero with PostgreSQL `23505`, and the drill asserts the
   per-migration transaction rolled back: history stays at 5 and no partial schema
   (`renewal_enabled`) leaked. This is the upgrade guard against incompatible live data.

Both side databases are dropped at the end (hard-coded names only). The baseline/seed SQL
and migrator logs stay in gitignored `secrets/` as evidence, and `migrationDrill`
(baseline/target migration IDs, preserved row counts, `idempotent`, `guardRejected`,
`dedupeRejected`, `identityRejected`) is recorded in `lab-state.json`. `verify.sh` re-checks
those values plus a live anchor that the main lab database itself is fully migrated (all 8
current migrations); without the entry that section is skipped.

## Revocation and CRL drill

`drill-revocation.sh` proves the Phase 7 completion condition: revocation reaches the CA
through a real ACME `revokeCert` call signed by the lab account key, the CA publishes it, and
the record is durable across a CA outage. `setup.sh` must have enabled CRL generation — the
drill starts by asserting the CA serves a CRL that carries an *Issuing Distribution Point*,
and fails immediately if step-ca is running without the `crl` block (an unreachable CRL
endpoint would otherwise look like a revocation bug). It then registers `svc5.trustforge.lab`
(`demo-tls-revocation`), writes its target registration and adds its Technitium A record, and
bootstraps it with a manual job so a real certificate is deployed and served.

1. **RBAC** — anonymous `POST /api/v1/services/{id}/revocations` is 401; the realm-imported
   `trustforge-cert-operator` user (password `LAB_OIDC_DEV_PASSWORD`) holds
   `CertificateOperator` but not `PlatformAdmin` and is **403** on the revocation POST while
   keeping 200 reads and 202 issuance. Revocation is deliberately narrower than issuance.
   That user comes from the Keycloak realm import (`TrustForge.Api/keycloak`), and `start-dev`
   keeps its H2 database inside the container, so a container that was created before the user
   existed must be recreated to re-import the realm
   (`compose up -d --force-recreate keycloak`, then wait for the realm endpoint) or step 1 fails
   with "does not hold CertificateOperator".
2. **Request validation and conflicts** — a missing `Idempotency-Key` and an unknown reason are
   400; a service with no active deployment is 409 `no_active_certificate`. The 409
   `service_job_active` guard is also probed against a job that was just created, but that
   window closes as the worker picks the job up, so the drill prints a NOTE instead of failing
   when it has already closed; `drill-renewal.sh` asserts the same guard deterministically.
3. **Real ACME revocation** — `POST` with `KeyCompromise` returns 200 `status: revoked` and a
   record whose `serial` equals the deployed certificate's CA-side serial (leading `00` DER pad
   stripped, so it matches `openssl`/CRL output), with `jobId`, `reason`, `requestedBy` (token
   `sub`) and `revokedAt` recorded.
4. **CRL distribution** — `lab-crl.sh` fetches `https://127.0.0.1:9000/1.0/crl` with full TLS
   verification against `secrets/root_ca.crt` (`server_hostname=step-ca`, nothing relaxed) and
   the serial must appear with reason `Key Compromise`.
5. **Audit** — exactly one delivered `CertificateRevoked` alert per serial, Critical for
   `KeyCompromise` and Warning for `Unspecified`, deduped on `revoked:{serial}`.
6. **Replay** — the same `Idempotency-Key` returns the same record, and a *fresh* key for the
   same serial also replays it (the live-serial guard), so the CA is never asked twice.
7. **Durable retry** — after re-issuing (new serial, proving revocation does not poison later
   issuance), `step-ca` is stopped and the replacement certificate is revoked: the request
   returns 202 `status: pending` with the row `Pending`. Restarting the CA lets
   `RevocationRetryWorker` finish it: `Revoked`, one row for that serial, `lastError` cleared,
   serial in the CRL, Warning alert, and no `RevocationFailed` give-up alert. A freshly queued
   row has `next_attempt_at IS NULL`, so it is instantly claimable and the inline attempt can
   lose the optimistic-concurrency guard to the worker; the drill asserts the row is Pending
   with a trace of the failure (an attempt count or a recorded error), not which writer made it.
8. **No collateral damage** — `svc1`'s active serial is absent from the CRL throughout, and the
   scoped audit export (`GET /api/v1/audit/export?serviceId=…`) carries both svc5 revocations
   and none of another service's.

The drill ends with a fresh `svc1` deployment so `svc1` owns the shared
`/etc/trustforge-demo/current` symlink again before `verify.sh` reads the served certificate,
and records `revocationDrill{serviceId, revocationId, serial, retryRevocationId, retrySerial,
unaffectedSerial, finalSvc1Serial, operatorUsername}` plus the new `jobId` in `lab-state.json`.
`verify.sh` re-checks those values — the CRL entries, record states, RBAC codes, alert severity
and replay — and scopes its "no revocation abandoned as `Failed`" and "no give-up alert"
invariants to the drill service, because the lab keeps the history of earlier runs.

## Expiry reminders and audit export

`verify.sh` also asserts the Phase 6 expiry-reminder and audit-export features:

- **Expiry reminders** — with `CertificateJobs__Expiry__ScanInterval=00:00:05` and
  `CertificateJobs__Expiry__ReminderWindow=7.00:00:00`, the 24h lab certificates are always
  inside the reminder window, so a `CertificateExpiring` Warning alert (no `jobId`,
  `dedupeKey=expiring:{serviceId}:{fingerprint}`) appears for the active `svc1` certificate,
  is delivered to the webhook receiver, and is deduplicated to exactly one row across
  repeated scans. The renewed `svc4` certificate raises its own reminder, and terminal
  failure alerts still carry a `jobId` with no `dedupeKey`.
- **Audit export** — `GET /api/v1/audit/export` returns a bundle containing the current job
  (with string-serialized transition states), the active deployment version and both failure
  and expiry alerts; the `serviceId` filter scopes every section, a future `from` yields an
  empty bundle, and anonymous access is rejected with 401.

## Notes

- The lab builds step-ca from source with a two-line patch (`step-ca/Dockerfile`).
  Upstream v0.30.2 (and master) corrupts the ACME account order index once every order
  of an account has completed: listing orders stores empty bytes (later reads fail with
  `error unmarshaling orderIDs ... unexpected end of JSON input`), and the empty-index
  create path mismatches the CmpAndSwap old value (`changed since last read`). The patch
  keeps an empty JSON array on both sides. The first build compiles step-ca and takes
  several minutes; Docker caches the layers afterwards.
- step-ca defaults to 24-hour certificate and order lifetimes; lab certificates expire
  daily. Automatic renewal (Phase 6) re-issues certificates whose active deployment enters
  the per-service `renewalLeadTime` window; see `drill-renewal.sh`.
- The demo health action exits successfully while no certificate is installed, because the
  pipeline's `Connecting` stage runs the health check before the first deployment.
- Recovery can be drilled manually: stop the app while a job is `AwaitingChallenge`
  (`docker compose stop trustforge`), start it again, and watch the job resume after the
  lease expires and still reach `Succeeded`. The challenge window is short (~100 ms with
  a local CA), so catching it requires freezing the process or slowing the pipeline.
- Recreating the app container (e.g. `docker compose up -d trustforge` after an image
  rebuild) invalidates Keycloak's shared network namespace: `docker compose restart
  keycloak` then fails with a stale-netns error. Use `docker compose up -d keycloak` to
  recreate it against the new namespace.
- `setup.sh` enables step-ca CRL generation (`ca.json` `crl` block) idempotently and restarts
  the CA; without it revocations are recorded by the CA but never published, and
  `drill-revocation.sh` fails its precondition on purpose rather than reporting a false pass.
- The scripts set `MSYS_NO_PATHCONV=1` so Git Bash leaves container paths (`/etc/...`) alone.
  That also stops MSYS from rewriting `-o /dev/null`: the native Windows `curl.exe` then tries
  to write a literal `/dev/null` and exits 23. Status-code probes therefore pipe the body away
  (`http_code` in `drill-revocation.sh` / `verify.sh`) instead of using `-o`.