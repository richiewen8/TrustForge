namespace TrustForge.Api;

public sealed class SmallstepAcmeOptions
{
    public string? DirectoryUrl { get; init; }
    public string? AccountEmail { get; init; }
    public string? AccountKeySecretRef { get; init; }
    public string? EabKeyId { get; init; }
    public string? EabKeySecretRef { get; init; }
    public string EabKeyAlgorithm { get; init; } = "HS256";
    public string? RootCertificatePath { get; init; }
    public TimeSpan HttpTimeout { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan AuthorizationTimeout { get; init; } = TimeSpan.FromMinutes(3);
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(2);
    public TimeSpan MaximumCertificateLifetime { get; init; } = TimeSpan.FromDays(90);
}
