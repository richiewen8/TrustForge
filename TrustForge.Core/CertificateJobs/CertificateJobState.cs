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
    Simulated,
    Failed,
    FailedRolledBack,
    RollbackFailed,
    Cancelled
}
