namespace TrustForge.Core.CertificateJobs;

public sealed class CertificateJobConcurrencyException : InvalidOperationException
{
    public CertificateJobConcurrencyException(Guid jobId, long expectedVersion, long? actualVersion)
        : base(actualVersion is null
            ? $"Certificate job '{jobId}' changed while the update was being saved."
            : $"Certificate job '{jobId}' is at version {actualVersion}, not expected version {expectedVersion}.")
    {
        JobId = jobId;
        ExpectedVersion = expectedVersion;
        ActualVersion = actualVersion;
    }

    public Guid JobId { get; }
    public long ExpectedVersion { get; }
    public long? ActualVersion { get; }
}
