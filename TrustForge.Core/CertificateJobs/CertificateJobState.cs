namespace TrustForge.Core.CertificateJobs;

public enum CertificateJobState
{
    Queued,
    Connecting,
    GeneratingCsr,
    CreatingOrder,
    AwaitingChallenge,
    Signing,
    Staging,
    Activating,
    Verifying,
    Succeeded,
    Failed,
    FailedRolledBack,
    RollbackFailed,
    Cancelled
}
