using System.Text.Json;
using TrustForge.Core.CertificateJobs;

namespace TrustForge.Api;

public interface ICertificateArtifactStore
{
    Task PutAsync(Guid jobId, IssuedCertificateBundle certificate, CancellationToken cancellationToken = default);
    Task<IssuedCertificateBundle> GetAsync(Guid jobId, CancellationToken cancellationToken = default);
}

/// <summary>Durable local storage for public certificate material; private keys are never accepted.</summary>
public sealed class FileCertificateArtifactStore(string directory) : ICertificateArtifactStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public async Task PutAsync(Guid jobId, IssuedCertificateBundle certificate, CancellationToken cancellationToken = default)
    {
        string target = GetPath(jobId);
        Directory.CreateDirectory(directory);
        string temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (FileStream stream = new(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 16 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, certificate, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }
            File.Move(temporary, target, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
                File.Delete(temporary);
        }
    }

    public async Task<IssuedCertificateBundle> GetAsync(Guid jobId, CancellationToken cancellationToken = default)
    {
        await using FileStream stream = new(GetPath(jobId), FileMode.Open, FileAccess.Read, FileShare.Read, 16 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        return await JsonSerializer.DeserializeAsync<IssuedCertificateBundle>(stream, JsonOptions, cancellationToken)
            ?? throw new InvalidOperationException("The persisted certificate artifact is empty.");
    }

    private string GetPath(Guid jobId) => Path.Combine(directory, $"{jobId:N}.certificate.json");
}
