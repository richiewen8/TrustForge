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

The same three TechnitiumLibrary projects and the same `dotnet publish TrustForge/TrustForge.Api` command run directly on an Ubuntu 24.04 host: `deploy/bare-metal/install.sh` does it there, keeping the .NET SDK inside a throwaway directory that it deletes afterwards. The same installer also consumes a published release package with no checkout and no SDK on the host — see [`BAREMETAL.md`](BAREMETAL.md), "Install from a release package".

## Release packaging and CI

`.github/workflows/linux-release.yml` is the only producer of release assets. Both repositories are
checked out as siblings under the workspace (`TrustForge/`, `TechnitiumLibrary/`) because that is the
layout above and the `HintPath` in `DnsServerCore.csproj:33-47` resolve against; the workspace root
becomes the Docker build context, with `Dockerfile.dockerignore` copied to it as `.dockerignore`.

The job runs the Dockerfile's own `build` stage (`--target build`), `docker cp`s `/out/publish`, and
passes it to `deploy/release/make-package.sh --app-dir … --out … --tag … --expect-library-ref …`. The
package is therefore the image's bytes by construction. Nothing is compiled a second time, and the
runner needs no .NET SDK.

Three version facts are asserted before any asset is published:

| Assertion | Where |
| --- | --- |
| `tag == v<Version>` from `TrustForge.Api/TrustForge.Api.csproj` | the workflow's "Resolve the version and tag" step, and `--tag` inside `make-package.sh` |
| the library checkout equals the pinned commit | `LIBRARY_PIN` in the workflow, and `--expect-library-ref` in the packager |
| the library's own `DnsServerCore` version matches the vendored one | `make-package.sh` compares `dns-server-v15.6.2` with the vendored `DnsServerCore.csproj` |

`v0.1.0` was built from `TechnitiumSoftware/TechnitiumLibrary` at
`4a5a530ac6c4114e72216e0b9c74208a7a5e3fa0` (tag `dns-server-v15.6.2`), engine version 15.6.2. That SHA
is the pin; it lives in the workflow `env`, in `MANIFEST.json` of every package, and in
`/var/lib/trustforge/install.json` on an installed host.

`MANIFEST.json`'s `baseImageDigest` is the digest the tag `mcr.microsoft.com/dotnet/sdk:10.0` resolved
to for that build — a rolling tag over a multi-platform manifest list, so the digest is what names the
bytes rather than the tag. The packager cannot resolve one itself (the base lands in BuildKit's cache,
not in the docker image store), so it reads `BASE_IMAGE_DIGEST` from its environment and downgrades any
value that is not `sha256:` plus 64 hex digits to `unknown`. The workflow asks the registry before and
after `docker build`, and fails the run when the tag moved or the second lookup came back empty: a
digest this build may not have used is worse than one that admits it is unknown. When the first lookup
itself fails, the build continues and `MANIFEST.json` says `unknown`.

To bump a release: change `<Version>` in `TrustForge.Api/TrustForge.Api.csproj`, land it on `master`,
update `LIBRARY_PIN`/`LIBRARY_TAG` in the workflow if the library moved (and `DnsServerCore.csproj`'s
`<Version>`, which the packager cross-checks), add `docs/release-notes/<new-tag>.md`, then tag
`v<new-version>` on a green `master`. The tag push runs verify → publish; a missing release-notes file
fails the build rather than publishing an empty body.

To run the checks without a runner: `bash deploy/bare-metal/build-and-verify-in-container.sh`. It
builds, packages, validates, lints, refuses hostile archives and parses the unit file, and it stops
short of what no container can prove — the on-target checklist in `BAREMETAL.md`.
