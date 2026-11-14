# TrustForge.Core

TrustForge's independent application/domain module. It is intentionally not referenced by the Technitium DNS Server projects; DNS integration will be added through an adapter boundary after the core service workflows are established.

The initial slice contains the certificate issuance/deployment job aggregate, guarded state transitions, transition history, idempotent job creation contract, and optimistic concurrency boundary. The planned issuance backend is Smallstep `step-ca` over ACME, with DNS-01 validation through Technitium. PostgreSQL is the selected persistence store (Npgsql + EF Core migrations); HTTP API, ACME client, DNS adapter, worker execution, SSH, and audit storage are subsequent layers.

Target framework follows the current repository toolchain (`net10.0`).
