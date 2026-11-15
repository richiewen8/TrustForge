namespace TrustForge.Api;

public sealed class CertificateAlertOptions
{
    /// <summary>Optional webhook receiver; when unset, alerts are delivered as structured log events only.</summary>
    public string? WebhookUrl { get; init; }
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(5);
    public TimeSpan VisibilityTimeout { get; init; } = TimeSpan.FromMinutes(1);
    public int MaxAttempts { get; init; } = 5;
}

public sealed class CertificateDeploymentOptions
{
    public int RetainedReleases { get; init; } = 3;
}