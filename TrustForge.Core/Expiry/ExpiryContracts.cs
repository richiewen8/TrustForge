namespace TrustForge.Core.Expiry;

public sealed record ExpiringCertificate(Guid ServiceId, string Fingerprint, DateTimeOffset NotAfter);

/// <summary>Reads active deployment certificates approaching expiry, independent of the renewal policy.</summary>
public interface IExpiryCandidateStore
{
    Task<IReadOnlyList<ExpiringCertificate>> ListExpiringAsync(DateTimeOffset now, TimeSpan reminderWindow, CancellationToken cancellationToken = default);
}