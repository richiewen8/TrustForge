namespace TrustForge.Api;

public sealed class CertificateJobWorkerOptions
{
    public bool Enabled { get; init; }
    public bool NotificationEnabled { get; init; } = true;
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(2);
    public TimeSpan LeaseDuration { get; init; } = TimeSpan.FromMinutes(2);
}
