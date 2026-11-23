# TrustForge on a physical Linux host (no Docker)

`deploy/bare-metal/install.sh` installs TrustForge as a systemd service on **Ubuntu 24.04**, with
PostgreSQL 17 from the PGDG apt repository, on a host with no container runtime. The build runs on
the target, so the machine needs the sibling `TechnitiumLibrary` checkout and outbound HTTPS to
`dot.net`, `api.nuget.org` and `apt.postgresql.org`.

Choose this over [DEPLOYMENT.md](DEPLOYMENT.md) when the certificate platform must live on hardware
that cannot run containers, or when you want the database and the service under the same host tooling
as the rest of the fleet. Choose Docker otherwise: the container path is what every drill in
`dev/acceptance/` and `dev/acme-lab/` has been validated against, and the container keeps a .NET SDK
off the machine entirely.

## What the installer does

```sh
sudo ./deploy/bare-metal/install.sh --check-only    # read-only preflight, changes nothing
sudo ./deploy/bare-metal/install.sh --dry-run       # preflight, then print the plan
sudo ./deploy/bare-metal/install.sh --oidc-authority https://id.internal/realms/trustforge \
                                    --oidc-audience trustforge-api
```

| Concern | Bare metal | Under Docker |
| --- | --- | --- |
| Process supervision | `systemctl start trustforge`, `journalctl -u trustforge` | container `restart: unless-stopped` |
| Migrations | `ExecStartPre=` in the unit, run once in the foreground at install | image entrypoint |
| PostgreSQL | PGDG `postgresql-17`, cluster `main`, loopback only | `postgres:17` container, unpublished |
| DNS config | `/etc/trustforge/dns` | named volume `trustforge-dns-config` |
| Certificate artifacts | `/var/lib/trustforge/artifacts` | named volume `trustforge-certificate-artifacts` |
| DNS logs | `/var/log/technitium/dns` | named volume `trustforge-dns-logs` |
| Secret files | `/etc/trustforge/secrets` (`root:trustforge` 0750, files 0640, **read-only to the service**) | `./secrets` bind-mounted read-only at `/run/trustforge/secrets` |
| Runtime config | `/etc/trustforge/trustforge.env` (0600, root) | `docker-compose.yml` environment block |
| Release layout | `/opt/trustforge/app/<release>` + `current` symlink | one immutable image |

The installer refuses to run unless: the host is Ubuntu 24.04 on systemd and not containerised,
port 53/tcp+udp and 5380/tcp and 5000/tcp are free, no Docker TrustForge stack exists on the host,
the TechnitiumLibrary projects are present, and PostgreSQL 17 is installable. It prints
`PASS/FAIL/NOTE` per check and changes nothing on a failure.

## Secret paths are a one-way decision

`secret://file//var/lib/trustforge/secrets/acme-account.pem` — the double slash is required, and the
path is read by **the service user** (`EnvironmentSecretResolver.cs:12-19` does a plain
`File.ReadAllText` with no ownership or permission checks). So the file mode is the only gate:
`0640 root:trustforge` inside `0750` directories, and never inside a directory the unit may write to.

Those paths are also stored **in the database** (each managed service's `sshCredentialRef`). Moving
the directory later means rewriting those rows. The installer therefore uses `/etc/trustforge/secrets`,
not `/run/trustforge/secrets`: `/run` is tmpfs, so under Docker the bind mount was what made those
files survive a reboot, and on a host there is nothing behind it.

`/run/trustforge/secrets` references copied from the Docker documentation will resolve to real host
paths on bare metal and silently read the wrong file if you happen to create one there.

## Settings frozen at first boot

This is the part that bites. The DNS engine reads every `DNS_SERVER_*` variable **only while the
matching config file does not exist** (`DnsWebService.cs:276-346`, `DnsServer.cs:472-599`,
`AuthManager.cs:950-951`); it then writes `dns.config`, `webservice.config` and `auth.config` and
reads only those forever. Editing `/etc/trustforge/trustforge.env` afterwards is a **silent no-op**.

| Variable | Value | Consequence if it was wrong at first boot |
| --- | --- | --- |
| `DNS_SERVER_WEB_SERVICE_LOCAL_ADDRESSES` | `127.0.0.1` | The console defaults to `0.0.0.0:5380` (`DnsWebService.cs:105,108`). Under Docker the `127.0.0.1:` host mapping was the only guard; on a host there is none, and the console is Technitium-authenticated, not OIDC. |
| `DNS_SERVER_ADMIN_PASSWORD_FILE` | `/etc/trustforge/secrets/dns-admin-password` | Without it the engine creates **admin/admin**. The variable also does **not** rotate the password once `auth.config` exists — rotate in the DNS console. |
| `DNS_SERVER_RECURSION` | `AllowOnlyForPrivateNetworks` | An open resolver on a physical network. |
| `DNS_SERVER_ENABLE_BLOCKING` | `false` | A blocklist enabled at seed time silently swallows `_acme-challenge` lookups and OIDC discovery. |
| `DNS_SERVER_LOG_MAX_LOG_FILE_DAYS`, `DNS_SERVER_STATS_MAX_STAT_FILE_DAYS` | 30 / 90 | A container volume gets pruned by `down -v`; `/var/log` on a host just fills. |
| Any listener on port 53 | — | **No environment variable moves the DNS port off 53.** `DnsServerHostedService.cs:24` passes `throwIfBindFails: true`, so an occupied 53 terminates the whole API process rather than degrading. |

The installer asserts the *real* sockets after startup (`ss` on 53/5380/5000) instead of trusting the
env file, and refuses to proceed quietly when the config is already seeded.

`ASPNETCORE_URLS` and everything under `CertificateJobs__`, `SmallstepAcme__`, `TechnitiumDns__` and
`Authentication__` are **not** frozen — those are re-read on every start, so `systemctl restart
trustforge` applies them.

### Re-seeding the DNS config

Only do this deliberately; the directory holds the zones.

```sh
sudo systemctl stop trustforge
sudo tar -czf /root/dns-config-$(date +%F).tar.gz -C /etc/trustforge dns   # zones, API tokens, users
sudo mv /etc/trustforge/dns /etc/trustforge/dns.broken-$(date +%s)
sudo install -d -m 0750 -o trustforge -g trustforge /etc/trustforge/dns
sudo systemctl start trustforge
```

Afterwards you must recreate the DNS-01 challenge zone, re-issue the least-privilege Technitium API
token that `TechnitiumDns:ApiTokenSecretRef` points at, and re-point step-ca's resolver at this host.

## Freeing port 53

The installer detects an occupied 53 and stops; it will not reconfigure your resolver. On a default
Ubuntu 24.04 install `systemd-resolved` holds `127.0.0.53:53`:

```sh
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/10-trustforge.conf
sudo systemctl restart systemd-resolved
sudo rm -f /etc/resolv.conf && printf 'nameserver 127.0.0.1\n' | sudo tee /etc/resolv.conf
```

Losing the stub listener means this host resolves through TrustForge itself once it is running, so
keep a working `DNS_SERVER_FORWARDERS` in the env file before the first start (`install.sh` leaves it
to the code default of public forwarders otherwise). `uninstall.sh` does not exist; to undo this,
delete the drop-in, restart `systemd-resolved`, and restore `/etc/resolv.conf`.

## TLS and exposure

`TrustForge.Api` has no Kestrel TLS configuration at all; the API is plaintext HTTP bound to
`127.0.0.1:5000`. Put nginx or caddy in front with a real certificate and proxy `/api` and
`/health`. Everything else stays loopback: the DNS console on `127.0.0.1:5380` (reach it through an
SSH tunnel, or bind it to a management interface you actually trust), and PostgreSQL on the unix
socket plus `127.0.0.1` only.

The unit is `ProtectSystem=strict` with an explicit `ReadWritePaths` list, `PrivateTmp`,
`NoNewPrivileges`, `RestrictAddressFamilies` and a `CapabilityBoundingSet` limited to
`CAP_NET_BIND_SERVICE` for port 53. Outbound, the process needs: NTP, the OIDC issuer, the step-ca
directory over HTTPS, TCP 22 to each managed service, and `https://go.technitium.com` (the engine's
update check is on by default, `DnsServer.cs:477`).

## Upgrade and rollback

```sh
sudo -u postgres pg_dump -U trustforge -d trustforge -Fc -f /root/trustforge-pre-upgrade.dump
sudo tar -czf /root/dns-config-pre-upgrade.tgz -C /etc/trustforge dns
cd /path/to/new/TrustForge
sudo ./deploy/bare-metal/install.sh --yes --skip-postgres --db-password-file /etc/trustforge/secrets/database-password \
    --oidc-authority "$(grep -oPm1 '(?<=^Authentication__Authority=).*' /etc/trustforge/trustforge.env)" \
    --oidc-audience "$(grep -oPm1 '(?<=^Authentication__Audience=).*' /etc/trustforge/trustforge.env)"
```

`--skip-postgres` keeps the existing cluster: the installer reuses the recorded password in
`/etc/trustforge/secrets/database-password` and never re-issues `CREATE ROLE`. The new release lands
beside the old one and `current` is repointed atomically; two superseded releases are kept.
`ExecStartPre` applies forward migrations on the next start, so the schema follows the new binary.

Rollback is `sudo ln -sfn /opt/trustforge/app/<previous> /opt/trustforge/app/.new && sudo mv -T /opt/trustforge/app/.new /opt/trustforge/app/current && sudo systemctl restart trustforge`. It is
only safe while migrations stay additive, exactly as in [OPERATIONS.md](OPERATIONS.md) section 3.3:
an older binary against a newer schema is unsupported, so restore the pre-upgrade dump if a
migration was destructive.

## Uninstall

```sh
sudo systemctl disable --now trustforge
sudo rm /etc/systemd/system/trustforge.service && sudo systemctl daemon-reload
sudo rm -rf /opt/trustforge /etc/trustforge/trustforge.env
```

That leaves the data alone on purpose: the PostgreSQL cluster and its dumps, `/etc/trustforge/dns`,
`/var/lib/trustforge` (artifacts) and `/etc/trustforge/secrets` (CA account key, DNS API token, SSH
deployer keys) all stay. Dropping the cluster or those directories is a separate, deliberate act —
follow [OPERATIONS.md](OPERATIONS.md) section 3 first so you hold a restore point.

## On-target checklist

The installer cannot verify these from itself. Run them before trusting the host; the last one is the
one that catches most mistakes.

1. `systemctl is-active trustforge` and `journalctl -u trustforge -p err --since "-5 min"` empty.
2. `curl -fsS http://127.0.0.1:5000/health/live` and `/health/ready` both 200 — `/health/ready` is 503
   while the database is unreachable or migrations are pending (`Program.cs:124-141`), and these two
   routes are the only anonymous ones.
3. `ss -Hltnp 'sport = :5380'` shows `127.0.0.1:5380` and **no** `0.0.0.0:5380`; same shape for 5000.
4. `ss -Hlunp 'sport = :53'` and `-Hltnp` both list the `dotnet` process.
5. `dig +short @127.0.0.1 SOA <your zone>` over UDP and with `+tcp` both answer.
6. Log into the console and confirm **admin/admin is rejected** — if it is accepted,
   `DNS_SERVER_ADMIN_PASSWORD_FILE` was not in the env file at first boot.
7. `sudo systemctl reboot`, then repeat 1–4. This is what proves the secrets are not sitting in tmpfs
   and that the host resolves without the stub listener.
8. Register one managed service, run the certificate pipeline end to end, then confirm a revocation
   actually reaches the CRL: `curl --cacert <root> <crl-url> | openssl crl -inform DER -noout -text`.

`dev/acceptance/preflight.sh` and `dev/acceptance/drill.sh` still work against this host: they talk to
the API and the CA over the network, not through Docker. They were written for the container stack, so
set `TF_API_URL=http://127.0.0.1:5000` and read their README for the rest.

## Checking these scripts without a target host

There is no CI in this repository, so run these yourself. From the repository root:

```sh
docker run --rm -e DEBIAN_FRONTEND=noninteractive -v "$PWD":/work -w /work ubuntu:24.04 bash -c \
  'apt-get update -qq && apt-get install -y -qq shellcheck systemd &&
   bash -n deploy/bare-metal/install.sh &&
   shellcheck -S style deploy/bare-metal/install.sh'
```

From Git Bash on Windows, prefix the `docker run` with `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'` or
`-w /work` is rewritten to a `C:/...` path the daemon rejects. `DEBIAN_FRONTEND=noninteractive` matters:
without it, the `systemd` package stops the container on a tzdata question.

`systemd-analyze verify` needs the paths the unit names, so stage them first or it reports `Command
/opt/dotnet/dotnet is not executable` — an artefact of the empty container, not a defect in the unit:

```sh
docker run --rm -e DEBIAN_FRONTEND=noninteractive -v "$PWD":/work -w /work ubuntu:24.04 bash -c \
  'apt-get update -qq && apt-get install -y -qq systemd &&
   install -d /opt/dotnet /opt/trustforge/app/current /etc/trustforge &&
   printf "#!/bin/sh\nexit 0\n" >|/opt/dotnet/dotnet && chmod 0755 /opt/dotnet/dotnet &&
   : >/opt/trustforge/app/current/TrustForge.dll && : >/etc/trustforge/trustforge.env &&
   systemd-analyze verify deploy/bare-metal/trustforge.service'
```

`install.sh --help` also catches the cheap failures. On Windows, watch line endings: `.gitattributes`
pins `*.sh`, `*.service` and `*.env*` to LF, because a CRLF unit file is rejected by systemd and a CRLF
env file appends `\r` to every value, including the database password.
