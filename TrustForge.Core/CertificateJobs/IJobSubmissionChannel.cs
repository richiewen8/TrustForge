namespace TrustForge.Core.CertificateJobs;

/// <summary>
/// Transactional wake hint for newly submitted certificate jobs. The durable job row remains the
/// source of truth; a missed notification only costs latency because the worker still polls.
/// </summary>
public interface IJobSubmissionChannel
{
    /// <summary>Returns true when a submission notification arrives, false when the timeout elapses.</summary>
    Task<bool> WaitForSubmissionAsync(TimeSpan timeout, CancellationToken cancellationToken = default);
}