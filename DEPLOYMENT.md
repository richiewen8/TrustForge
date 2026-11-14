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

## Open the project

Open `TrustForge.sln` in Visual Studio or `dotnet build TrustForge.sln`. This solution contains TrustForge and the Linux-compatible DNS engine/projects. The Windows service and system tray launchers are not part of TrustForge's supported deployment.
