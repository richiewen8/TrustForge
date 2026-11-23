# TrustForge

TrustForge combines internal PKI and certificate lifecycle management with the Technitium DNS Server engine in one Linux application. The DNS engine is embedded in the TrustForge process; PostgreSQL is its persistent data service, and an external OIDC provider supplies API identity.

## Open and build

Open [`TrustForge.sln`](TrustForge.sln) in Visual Studio, or build it with the .NET 10 SDK:

```sh
dotnet build TrustForge.sln
```

The solution includes the TrustForge API, domain and persistence modules, DNS core, and Linux-compatible DNS applications. Windows service and system tray launchers are not supported TrustForge deployment targets.

## Deploy on Linux

Two supported deployment shapes: [`DEPLOYMENT.md`](DEPLOYMENT.md) for Docker Compose — one TrustForge application container plus PostgreSQL, which is what the lab and acceptance drills validate — or [`BAREMETAL.md`](BAREMETAL.md) for a systemd service on a physical Ubuntu 24.04 host with no container runtime, installed by `deploy/bare-metal/install.sh`. Both embed the DNS engine in the TrustForge process; neither deploys a separate Technitium DNS Server. They cover the same endpoints, and their persistent-state locations differ.

## Current capabilities

- PostgreSQL persistence for managed Linux services, certificate jobs, and job state history.
- OIDC JWT authentication with role based API authorization.
- API endpoints for service registration and manual certificate job creation and status queries.
- Embedded Technitium DNS service, including its DNS protocol ports and administration console.
- Linux service deployment model using SSH host key fingerprints and external secret references.

Certificate issuance, durable worker execution, SSH certificate deployment, health checking, rollback, and scheduled renewal remain staged implementation work. See [`IMPLEMENTATION-PLAN.md`](IMPLEMENTATION-PLAN.md) and [`TRUSTFORGE-ARCHITECTURE.md`](TRUSTFORGE-ARCHITECTURE.md).

## Upstream DNS engine

TrustForge builds on the [Technitium DNS Server](https://github.com/TechnitiumSoftware/DnsServer) and its [TechnitiumLibrary](https://github.com/TechnitiumSoftware/TechnitiumLibrary). Their source remains in this repository and sibling checkout as build inputs. The DNS web console retains its separate authentication configuration for now; TrustForge API OIDC/RBAC does not yet provide a unified console login.
