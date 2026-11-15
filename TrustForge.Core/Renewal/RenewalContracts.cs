namespace TrustForge.Core.Renewal;

public static class CertificateRenewal
{
    public const string RequestedBy = "renewal-scheduler";
}

/// <summary>A service whose active certificate has entered its renewal window.</summary>
public sealed record RenewalCandidate(Guid ServiceId, string Fingerprint, DateTimeOffset NotAfter);

public interface IRenewalCandidateStore
{
    Task<IReadOnlyList<RenewalCandidate>> ListDueAsync(DateTimeOffset now, TimeSpan minimumRenewalInterval, CancellationToken cancellationToken = default);
}