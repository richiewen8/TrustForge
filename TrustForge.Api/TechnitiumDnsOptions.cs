namespace TrustForge.Api;

public sealed class TechnitiumDnsOptions
{
    public string? BaseUrl { get; init; }
    public string? ApiTokenSecretRef { get; init; }
    public string[] AllowedZones { get; init; } = [];
    public string ResolverAddress { get; init; } = "127.0.0.1";
    public int ResolverPort { get; init; } = 53;
    public int RecordTtlSeconds { get; init; } = 60;
    public int RecordExpiryTtlSeconds { get; init; } = 3600;
    public TimeSpan PropagationTimeout { get; init; } = TimeSpan.FromMinutes(3);
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(2);
}
