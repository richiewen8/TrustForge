namespace TrustForge.Persistence.ManagedServices;

internal sealed class ManagedServiceRecord
{
    public Guid Id { get; set; }
    public required string Name { get; set; }
    public required string Environment { get; set; }
    public required string Owner { get; set; }
    public required string Host { get; set; }
    public int Port { get; set; }
    public required string HostKeyFingerprint { get; set; }
    public required string SshCredentialRef { get; set; }
    public Guid ProfileId { get; set; }
    public string[] Sans { get; set; } = [];
    public required string CertificatePath { get; set; }
    public required string ChainPath { get; set; }
    public required string PrivateKeyPath { get; set; }
    public required string FileOwner { get; set; }
    public required string FileGroup { get; set; }
    public required string FileMode { get; set; }
    public required string RemoteHelperId { get; set; }
    public required string ReloadActionId { get; set; }
    public required string HealthCheckId { get; set; }
    public bool RenewalEnabled { get; set; }
    public TimeSpan RenewalLeadTime { get; set; }
    public bool Enabled { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}
