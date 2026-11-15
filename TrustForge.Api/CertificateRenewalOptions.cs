namespace TrustForge.Api;

public sealed class CertificateRenewalOptions
{
    public TimeSpan ScanInterval { get; set; } = TimeSpan.FromMinutes(5);
    public TimeSpan MinimumRenewalInterval { get; set; } = TimeSpan.FromHours(1);
}