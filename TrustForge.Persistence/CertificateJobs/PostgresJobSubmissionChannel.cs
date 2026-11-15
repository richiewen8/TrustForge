using System.Data;
using Microsoft.Extensions.Logging;
using Npgsql;
using TrustForge.Core.CertificateJobs;

namespace TrustForge.Persistence.CertificateJobs;

/// <summary>
/// Dedicated PostgreSQL LISTEN connection that wakes the worker as soon as a job is submitted.
/// The durable job row stays the source of truth; a missed notification only costs latency because
/// the worker still polls. One connection per process, kept open outside the Npgsql pool.
/// </summary>
public sealed class PostgresJobSubmissionChannel : IJobSubmissionChannel, IAsyncDisposable
{
    public const string SubmissionChannelName = "trustforge_job_submitted";

    private readonly string _connectionString;
    private readonly ILogger<PostgresJobSubmissionChannel> _logger;
    private NpgsqlConnection? _connection;
    private DateTimeOffset _reconnectNotBefore = DateTimeOffset.MinValue;

    public PostgresJobSubmissionChannel(string connectionString, ILogger<PostgresJobSubmissionChannel> logger)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        _logger = logger;
        _connectionString = new NpgsqlConnectionStringBuilder(connectionString)
        {
            Pooling = false,
            KeepAlive = 30,
            ApplicationName = "trustforge-job-listener",
        }.ConnectionString;
    }

    public async Task<bool> WaitForSubmissionAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        try
        {
            TimeSpan cooldown = _reconnectNotBefore - DateTimeOffset.UtcNow;
            if (cooldown > TimeSpan.Zero)
            {
                await Task.Delay(cooldown < timeout ? cooldown : timeout, cancellationToken);
                return false;
            }

            NpgsqlConnection connection = await EnsureListeningAsync(cancellationToken);
            return await connection.WaitAsync(timeout, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            _logger.LogWarning(exception, "Job submission listener failed; the worker falls back to polling.");
            await ResetConnectionAsync();
            _reconnectNotBefore = DateTimeOffset.UtcNow.AddSeconds(2);
            return false;
        }
    }

    private async Task<NpgsqlConnection> EnsureListeningAsync(CancellationToken cancellationToken)
    {
        if (_connection is { State: ConnectionState.Open })
            return _connection;

        await ResetConnectionAsync();
        NpgsqlConnection connection = new(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using NpgsqlCommand command = new($"LISTEN {SubmissionChannelName}", connection);
        await command.ExecuteNonQueryAsync(cancellationToken);
        _connection = connection;
        return connection;
    }

    private async Task ResetConnectionAsync()
    {
        if (_connection is not null)
        {
            await _connection.DisposeAsync();
            _connection = null;
        }
    }

    public async ValueTask DisposeAsync() => await ResetConnectionAsync();
}