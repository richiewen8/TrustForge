namespace TrustForge.Core.CertificateJobs;

public sealed record CertificateJobDnsChallengeCheckpoint(string AuthorizationUrl, string RecordName, string TxtValue);

/// <summary>
/// Non-secret recovery references for external work. Never place private keys, credentials,
/// bearer tokens, or certificate private-key material in this object.
/// </summary>
public sealed record CertificateJobCheckpoint(
    string? CsrPem = null,
    string? AcmeOrderUrl = null,
    IReadOnlyList<CertificateJobDnsChallengeCheckpoint>? DnsChallenges = null,
    string? CertificateArtifactRef = null,
    string? DeploymentReleaseId = null,
    string? PreviousReleaseId = null);
