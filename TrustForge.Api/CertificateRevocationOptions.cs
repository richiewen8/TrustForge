namespace TrustForge.Api;

public sealed class CertificateRevocationOptions
{
    public bool Enabled { get; init; } = true;
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan VisibilityTimeout { get; init; } = TimeSpan.FromMinutes(2);
    public int MaxAttempts { get; init; } = 5;
}
