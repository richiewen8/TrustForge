# TrustForge build

## Local development on Windows

Install the .NET 10 SDK and open `TrustForge.sln` in Visual Studio, or run:

```powershell
dotnet build TrustForge.sln
```

TrustForge is a Linux deployment product. Windows is supported as a development workstation only; the TrustForge DNS/PKI application is deployed on Linux.

## Linux Docker deployment

The Docker build expects this directory layout so the DNS engine can compile against TechnitiumLibrary source:

```text
parent/
├── TechnitiumLibrary/
└── TrustForge/
```

From the TrustForge directory, configure `.env` using `.env.trustforge.example`, then run:

```sh
docker compose up -d --build
```

The root Dockerfile builds the required TechnitiumLibrary components and publishes the TrustForge API host with the embedded DNS engine into a single TrustForge image. PostgreSQL runs as a companion service in the same Compose stack. See `DEPLOYMENT.md` for ports, OIDC setup, and persistent data.

## Linux bare-metal build

The same three TechnitiumLibrary projects and the same `dotnet publish TrustForge/TrustForge.Api` command run directly on an Ubuntu 24.04 host: `deploy/bare-metal/install.sh` does it there, keeping the .NET SDK inside a throwaway directory that it deletes afterwards. See [`BAREMETAL.md`](BAREMETAL.md).
