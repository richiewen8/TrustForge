namespace TrustForge.Core.CertificateJobs;

public sealed class InvalidCertificateJobTransitionException : InvalidOperationException
{
    public InvalidCertificateJobTransitionException(CertificateJobState current, CertificateJobState requested)
        : base($"Certificate job cannot transition from '{current}' to '{requested}'.")
    {
        CurrentState = current;
        RequestedState = requested;
    }

    public CertificateJobState CurrentState { get; }
    public CertificateJobState RequestedState { get; }
}
