namespace TrustForge.Api;

public sealed class CertificateExpiryOptions
{
    public TimeSpan ScanInterval { get; set; } = TimeSpan.FromHours(1);
    public TimeSpan ReminderWindow { get; set; } = TimeSpan.FromDays(7);
}