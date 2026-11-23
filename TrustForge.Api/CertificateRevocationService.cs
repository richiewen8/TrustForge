using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateAlerts;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.DeploymentVersions;
using TrustForge.Core.ManagedServices;
using TrustForge.Core.Revocation;

namespace TrustForge.Api;

public enum RevocationStatus
{
    Revoked,
    PendingRetry,
    Replayed,
    ServiceNotFound,
    NoActiveCertificate,
    JobActive,
    CertificateMaterialMissing,
    FingerprintMismatch
}

public sealed record RevocationResult(RevocationStatus Status, CertificateRevocation? Revocation, string? Error = null);

/// <summary>
/// Turns an operator request into a durable revocation record and drives it to the CA. The CA attempt and
/// its audit alert are committed together, and a failed attempt stays queued for the retry worker.
/// </summary>
public sealed class CertificateRevocationService(
    IManagedServiceStore services,
    IDeploymentVersionStore versions,
    ICertificateJobStore jobs,
    ICertificateArtifactStore artifacts,
    ICertificateRevocationStore revocations,
    ICertificateRevocationChannel channel,
    IOptions<CertificateRevocationOptions> options,
    ILogger<CertificateRevocationService> logger)
{
    private readonly CertificateRevocationOptions _options = options.Value;

    public async Task<RevocationResult> RequestAsync(
        Guid serviceId,
        CertificateRevocationReason reason,
        string idempotencyKey,
        string requestedBy,
        CancellationToken cancellationToken = default)
    {
        ManagedService? service = await services.FindByIdAsync(serviceId, cancellationToken);
        if (service is null)
            return new RevocationResult(RevocationStatus.ServiceNotFound, null);

        CertificateRevocation? replay = await revocations.FindByIdempotencyKeyAsync(idempotencyKey, cancellationToken);
        if (replay is not null)
            return new RevocationResult(RevocationStatus.Replayed, replay);

        DeploymentVersion? active = (await versions.ListByServiceAsync(serviceId, 20, cancellationToken))
            .FirstOrDefault(version => version.Status == DeploymentVersionStatus.Active);
        if (active is null)
            return new RevocationResult(RevocationStatus.NoActiveCertificate, null);

        // ux_certificate_jobs_active_service rejects any newer submission while a job runs, so the newest
        // job is the only one that can still be in flight.
        CertificateJob? newest = (await jobs.ListAsync(serviceId, null, null, 1, cancellationToken)).FirstOrDefault();
        if (newest is not null && !CertificateJob.IsTerminal(newest.State))
            return new RevocationResult(RevocationStatus.JobActive, null, newest.Id.ToString("N"));

        IssuedCertificateBundle? bundle = await ReadArtifactAsync(active.JobId, cancellationToken);
        if (bundle is null)
            return new RevocationResult(RevocationStatus.CertificateMaterialMissing, null);
        if (!string.Equals(bundle.FingerprintSha256, active.Fingerprint, StringComparison.OrdinalIgnoreCase))
            return new RevocationResult(RevocationStatus.FingerprintMismatch, null);

        string serial = ReadSerial(bundle.LeafCertificatePem);
        CertificateRevocation? live = await revocations.FindLiveBySerialAsync(serial, cancellationToken);
        if (live is not null)
            return new RevocationResult(RevocationStatus.Replayed, live);

        CertificateRevocation pending = new(
            Guid.NewGuid(), serviceId, active.JobId, active.Fingerprint, serial, reason,
            requestedBy, idempotencyKey, DateTimeOffset.UtcNow, CertificateRevocationState.Pending, 0);
        if (!await revocations.TryAddAsync(pending, cancellationToken))
        {
            CertificateRevocation? raced = await revocations.FindByIdempotencyKeyAsync(idempotencyKey, cancellationToken)
                ?? await revocations.FindLiveBySerialAsync(serial, cancellationToken);
            return new RevocationResult(RevocationStatus.Replayed, raced);
        }

        bool revoked = await CompleteAsync(pending, cancellationToken);
        CertificateRevocation? final = await revocations.FindByIdAsync(pending.Id, cancellationToken);
        return new RevocationResult(
            revoked ? RevocationStatus.Revoked : RevocationStatus.PendingRetry,
            final ?? pending with { State = revoked ? CertificateRevocationState.Revoked : CertificateRevocationState.Pending });
    }

    /// <summary>Attempts one queued revocation; used inline by the API and again by the retry worker.</summary>
    public async Task<bool> CompleteAsync(CertificateRevocation revocation, CancellationToken cancellationToken = default)
    {
        IssuedCertificateBundle? bundle = await ReadArtifactAsync(revocation.JobId, cancellationToken);
        if (bundle is not null && !string.Equals(bundle.FingerprintSha256, revocation.Fingerprint, StringComparison.OrdinalIgnoreCase))
            bundle = null;

        try
        {
            if (bundle is null)
                throw new InvalidOperationException("The stored certificate material for this revocation is missing.");
            RevocationReceipt receipt = await channel.RevokeAsync(bundle.LeafCertificatePem, revocation.Reason, cancellationToken);
            if (!await revocations.MarkRevokedAsync(
                    revocation.Id,
                    CertificateAlert.ForRevocation(
                        revocation.ServiceId, revocation.JobId, revocation.Serial, revocation.Fingerprint,
                        revocation.Reason, revocation.RequestedBy, receipt.RevokedAt),
                    receipt.RevokedAt,
                    cancellationToken))
                logger.LogInformation("Revocation {RevocationId} was already recorded as revoked.", revocation.Id);
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            bool giveUp = revocation.AttemptCount >= _options.MaxAttempts;
            logger.LogWarning(exception, "Revocation {RevocationId} attempt {Attempt} failed.", revocation.Id, revocation.AttemptCount);
            await revocations.MarkAttemptFailedAsync(
                revocation.Id,
                revocation.AttemptCount,
                exception.Message,
                giveUp ? null : GetRetryDelay(revocation.AttemptCount),
                giveUp ? CertificateAlert.ForRevocationFailed(revocation.ServiceId, revocation.JobId, revocation.Serial, exception.Message, DateTimeOffset.UtcNow) : null,
                cancellationToken);
            return false;
        }
    }

    private async Task<IssuedCertificateBundle?> ReadArtifactAsync(Guid jobId, CancellationToken cancellationToken)
    {
        try
        {
            return await artifacts.GetAsync(jobId, cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return null;
        }
    }

    private static string ReadSerial(string certificatePem)
    {
        using X509Certificate2 leaf = X509Certificate2.CreateFromPem(certificatePem);
        string hex = leaf.SerialNumber.ToUpperInvariant();
        // A DER INTEGER pads a high-bit serial with a leading 00 byte; the CA's CRL and openssl print it
        // without that pad, so strip it to keep revocation records correlatable with CRL entries.
        return hex.StartsWith("00", StringComparison.Ordinal) && hex.Length > 2 ? hex[2..] : hex;
    }

    private static TimeSpan GetRetryDelay(int attemptCount)
    {
        int exponent = Math.Clamp(attemptCount, 1, 8);
        return TimeSpan.FromSeconds(Math.Min(300, Math.Pow(2, exponent)));
    }
}
