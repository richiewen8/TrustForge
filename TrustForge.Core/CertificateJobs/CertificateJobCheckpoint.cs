namespace TrustForge.Core.CertificateJobs;

/// <summary>
/// Non-secret recovery references for external work. Never place private keys, credentials,
/// bearer tokens, or certificate private-key material in this object.
/// </summary>
public sealed record CertificateJobCheckpoint(
    string? CsrPem = null,
    string? AcmeOrderUrl = null,
    string? AcmeAuthorizationUrl = null,
    string? DnsRecordName = null,
    string? DnsTxtValue = null,
    string? CertificateArtifactRef = null,
    string? DeploymentReleaseId = null,
    string? PreviousReleaseId = null);
