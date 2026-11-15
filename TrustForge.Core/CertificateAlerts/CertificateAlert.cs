using TrustForge.Core.CertificateJobs;

namespace TrustForge.Core.CertificateAlerts;

public enum CertificateAlertKind
{
    JobFailed,
    DeploymentRolledBack,
    RollbackFailed,
    CertificateExpiring
}

public enum CertificateAlertSeverity
{
    Warning,
    Critical
}

public enum CertificateAlertDeliveryState
{
    Pending,
    Delivered,
    Failed
}

/// <summary>Durable failure notification, created in the same transaction as the terminal failure transition.</summary>
public sealed record CertificateAlert(
    Guid Id,
    Guid? JobId,
    Guid ServiceId,
    CertificateAlertKind Kind,
    CertificateAlertSeverity Severity,
    string Stage,
    string Summary,
    DateTimeOffset OccurredAt,
    CertificateAlertDeliveryState DeliveryState,
    int AttemptCount,
    DateTimeOffset? NextAttemptAt,
    DateTimeOffset? DeliveredAt,
    string? LastError,
    string? DedupeKey = null)
{
    public static CertificateAlert? ForTerminalFailure(CertificateJob job, DateTimeOffset occurredAt)
    {
        (CertificateAlertKind Kind, CertificateAlertSeverity Severity)? mapping = job.State switch
        {
            CertificateJobState.Failed => (CertificateAlertKind.JobFailed, CertificateAlertSeverity.Warning),
            CertificateJobState.FailedRolledBack => (CertificateAlertKind.DeploymentRolledBack, CertificateAlertSeverity.Warning),
            CertificateJobState.RollbackFailed => (CertificateAlertKind.RollbackFailed, CertificateAlertSeverity.Critical),
            _ => null
        };
        if (mapping is null)
            return null;

        return new CertificateAlert(
            Guid.NewGuid(),
            job.Id,
            job.ServiceId,
            mapping.Value.Kind,
            mapping.Value.Severity,
            job.FailureStage!,
            job.FailureSummary!,
            occurredAt,
            CertificateAlertDeliveryState.Pending,
            0,
            null,
            null,
            null);
    }

    public static CertificateAlert ForExpiring(Guid serviceId, string fingerprint, DateTimeOffset notAfter, DateTimeOffset occurredAt)
    {
        return new CertificateAlert(
            Guid.NewGuid(),
            null,
            serviceId,
            CertificateAlertKind.CertificateExpiring,
            CertificateAlertSeverity.Warning,
            "Expiry",
            $"Certificate for service {serviceId} (fingerprint {fingerprint}) expires at {notAfter:O}.",
            occurredAt,
            CertificateAlertDeliveryState.Pending,
            0,
            null,
            null,
            null,
            $"expiring:{serviceId}:{fingerprint}");
    }
}