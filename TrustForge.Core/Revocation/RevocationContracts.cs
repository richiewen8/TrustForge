namespace TrustForge.Core.Revocation;

public enum CertificateRevocationReason
{
    Unspecified = 0,
    KeyCompromise = 1,
    CaCompromise = 2,
    AffiliationChanged = 3,
    Superseded = 4,
    CessationOfOperation = 5
}

public enum CertificateRevocationState
{
    Pending,
    Revoked,
    Failed
}

/// <summary>Durable record of one operator-requested revocation of a certificate already handed to a service.</summary>
public sealed record CertificateRevocation(
    Guid Id,
    Guid ServiceId,
    Guid JobId,
    string Fingerprint,
    string Serial,
    CertificateRevocationReason Reason,
    string RequestedBy,
    string IdempotencyKey,
    DateTimeOffset RequestedAt,
    CertificateRevocationState State,
    int AttemptCount,
    DateTimeOffset? RevokedAt = null,
    DateTimeOffset? NextAttemptAt = null,
    string? LastError = null);

/// <summary>CA-side confirmation of a revocation.</summary>
public sealed record RevocationReceipt(bool AlreadyRevoked, DateTimeOffset RevokedAt);

/// <summary>Revokes a certificate at the CA. Implementations must treat an already-revoked certificate as success.</summary>
public interface ICertificateRevocationChannel
{
    Task<RevocationReceipt> RevokeAsync(
        string certificatePem,
        CertificateRevocationReason reason,
        CancellationToken cancellationToken = default);
}

public interface ICertificateRevocationStore
{
    Task<bool> TryAddAsync(CertificateRevocation revocation, CancellationToken cancellationToken = default);
    Task<CertificateRevocation?> FindByIdAsync(Guid id, CancellationToken cancellationToken = default);
    Task<CertificateRevocation?> FindByIdempotencyKeyAsync(string idempotencyKey, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CertificateRevocation>> ListAsync(Guid? serviceId, DateTimeOffset? from, DateTimeOffset? to, int limit, CancellationToken cancellationToken = default);
    Task<CertificateRevocation?> FindLiveBySerialAsync(string serial, CancellationToken cancellationToken = default);
    Task<bool> MarkRevokedAsync(Guid id, CertificateAlerts.CertificateAlert alert, DateTimeOffset occurredAt, CancellationToken cancellationToken = default);
    Task<bool> MarkAttemptFailedAsync(Guid id, int expectedAttemptCount, string error, TimeSpan? retryDelay, CertificateAlerts.CertificateAlert? terminalAlert, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CertificateRevocation>> ClaimDueAsync(int limit, TimeSpan visibilityTimeout, CancellationToken cancellationToken = default);
}
