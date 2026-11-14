using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.ManagedServices;
using TrustForge.Persistence;

WebApplicationBuilder builder = WebApplication.CreateBuilder(args);
string? connectionString = builder.Configuration.GetConnectionString("TrustForge");
if (string.IsNullOrWhiteSpace(connectionString))
    throw new InvalidOperationException("Configure ConnectionStrings:TrustForge using protected runtime configuration.");

builder.Services.AddTrustForgePersistence(connectionString);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddScoped<CertificateJobCoordinator>();

if (args.Contains("--migrate", StringComparer.Ordinal))
{
    WebApplication migrationApp = builder.Build();
    await using AsyncServiceScope scope = migrationApp.Services.CreateAsyncScope();
    await scope.ServiceProvider.GetRequiredService<TrustForgeDatabaseMigrator>().ApplyAsync();
    return;
}

string? authority = builder.Configuration["Authentication:Authority"];
string? audience = builder.Configuration["Authentication:Audience"];
if (!Uri.TryCreate(authority, UriKind.Absolute, out Uri? authorityUri)
    || authorityUri.Scheme != Uri.UriSchemeHttps
    || string.IsNullOrWhiteSpace(audience))
{
    throw new InvalidOperationException("Configure an HTTPS Authentication:Authority and Authentication:Audience before starting the API.");
}

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = authority;
        options.Audience = audience;
        options.RequireHttpsMetadata = true;
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            NameClaimType = "sub",
            RoleClaimType = "role"
        };
    });

builder.Services.AddAuthorization(options =>
{
    options.FallbackPolicy = new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build();
    options.AddPolicy("CertificateOperator", policy => policy.RequireRole("PlatformAdmin", "CertificateOperator"));
    options.AddPolicy("CertificateReader", policy => policy.RequireRole("PlatformAdmin", "CertificateOperator", "Auditor"));
});

WebApplication app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/health/live", () => Results.Ok(new { status = "live" })).AllowAnonymous();
app.MapGet("/health/ready", async (IDbContextFactory<TrustForgeDbContext> contextFactory, CancellationToken cancellationToken) =>
{
    try
    {
        await using TrustForgeDbContext db = await contextFactory.CreateDbContextAsync(cancellationToken);
        bool canConnect = await db.Database.CanConnectAsync(cancellationToken);
        string[] pending = canConnect
            ? (await db.Database.GetPendingMigrationsAsync(cancellationToken)).ToArray()
            : ["database-unavailable"];
        return canConnect && pending.Length == 0
            ? Results.Ok(new { status = "ready" })
            : Results.Problem("PostgreSQL is unavailable or schema migrations are pending.", statusCode: StatusCodes.Status503ServiceUnavailable);
    }
    catch
    {
        return Results.Problem("PostgreSQL readiness check failed.", statusCode: StatusCodes.Status503ServiceUnavailable);
    }
}).AllowAnonymous();

RouteGroupBuilder api = app.MapGroup("/api/v1");

api.MapPost("/services", async (
    CreateManagedServiceRequest request,
    IManagedServiceStore services,
    TimeProvider timeProvider,
    CancellationToken cancellationToken) =>
{
    if (!request.TryCreate(timeProvider.GetUtcNow(), out ManagedService? service, out Dictionary<string, string[]> errors))
        return Results.ValidationProblem(errors);

    bool added = await services.TryAddAsync(service!, cancellationToken);
    if (!added)
        return Results.Conflict(new { error = "service_id_conflict" });

    return Results.Created($"/api/v1/services/{service!.Id}", ManagedServiceResponse.From(service));
})
.RequireAuthorization("CertificateOperator");

api.MapGet("/services/{id:guid}", async (Guid id, IManagedServiceStore services, CancellationToken cancellationToken) =>
{
    ManagedService? service = await services.FindByIdAsync(id, cancellationToken);
    return service is null ? Results.NotFound() : Results.Ok(ManagedServiceResponse.From(service));
})
.RequireAuthorization("CertificateReader");

api.MapPost("/services/{id:guid}/certificate-jobs", async (
    Guid id,
    HttpRequest request,
    ClaimsPrincipal principal,
    IManagedServiceStore services,
    CertificateJobCoordinator coordinator,
    CancellationToken cancellationToken) =>
{
    ManagedService? service = await services.FindByIdAsync(id, cancellationToken);
    if (service is null)
        return Results.NotFound();
    if (!service.Enabled)
        return Results.Conflict(new { error = "service_disabled" });

    string? subject = principal.FindFirstValue("sub");
    if (string.IsNullOrWhiteSpace(subject))
        return Results.Forbid();

    string idempotencyKey = request.Headers["Idempotency-Key"].ToString();
    if (string.IsNullOrWhiteSpace(idempotencyKey) || idempotencyKey.Length > 200)
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["Idempotency-Key"] = ["A key between 1 and 200 characters is required."] });

    CertificateJob job = await coordinator.CreateManualJobAsync(id, subject, idempotencyKey, cancellationToken);
    return Results.Accepted($"/api/v1/certificate-jobs/{job.Id}", CertificateJobResponse.From(job));
})
.RequireAuthorization("CertificateOperator");

api.MapGet("/certificate-jobs/{id:guid}", async (
    Guid id,
    ICertificateJobStore jobs,
    CancellationToken cancellationToken) =>
{
    CertificateJob? job = await jobs.FindByIdAsync(id, cancellationToken);
    return job is null ? Results.NotFound() : Results.Ok(CertificateJobResponse.From(job));
})
.RequireAuthorization("CertificateReader");

await app.RunAsync();

internal sealed record CreateManagedServiceRequest(
    string? Name,
    string? Environment,
    string? Owner,
    string? Host,
    int Port,
    string? HostKeyFingerprint,
    string? SshCredentialRef,
    Guid ProfileId,
    string[]? Sans,
    string? CertificatePath,
    string? ChainPath,
    string? PrivateKeyPath,
    string? FileOwner,
    string? FileGroup,
    string? FileMode,
    string? RemoteHelperId,
    string? ReloadActionId,
    string? HealthCheckId)
{
    public bool TryCreate(
        DateTimeOffset now,
        out ManagedService? service,
        out Dictionary<string, string[]> errors)
    {
        Dictionary<string, List<string>> validationErrors = [];
        CheckRequired(Name, nameof(Name), 128, validationErrors);
        CheckRequired(Environment, nameof(Environment), 64, validationErrors);
        CheckRequired(Owner, nameof(Owner), 256, validationErrors);
        CheckRequired(Host, nameof(Host), 253, validationErrors);
        CheckRequired(HostKeyFingerprint, nameof(HostKeyFingerprint), 128, validationErrors);
        CheckRequired(SshCredentialRef, nameof(SshCredentialRef), 512, validationErrors);
        CheckRequired(CertificatePath, nameof(CertificatePath), 1024, validationErrors);
        CheckRequired(ChainPath, nameof(ChainPath), 1024, validationErrors);
        CheckRequired(PrivateKeyPath, nameof(PrivateKeyPath), 1024, validationErrors);
        CheckRequired(FileOwner, nameof(FileOwner), 32, validationErrors);
        CheckRequired(FileGroup, nameof(FileGroup), 32, validationErrors);
        CheckRequired(FileMode, nameof(FileMode), 4, validationErrors);
        CheckRequired(RemoteHelperId, nameof(RemoteHelperId), 64, validationErrors);
        CheckRequired(ReloadActionId, nameof(ReloadActionId), 64, validationErrors);
        CheckRequired(HealthCheckId, nameof(HealthCheckId), 64, validationErrors);

        if (Port is < 1 or > 65535)
            AddError(validationErrors, nameof(Port), "Port must be between 1 and 65535.");
        if (ProfileId == Guid.Empty)
            AddError(validationErrors, nameof(ProfileId), "A certificate profile ID is required.");
        if (Host is not null && Uri.CheckHostName(Host.Trim()) == UriHostNameType.Unknown && !System.Net.IPAddress.TryParse(Host.Trim(), out _))
            AddError(validationErrors, nameof(Host), "Host must be a DNS name or IP address.");
        if (HostKeyFingerprint is not null && !System.Text.RegularExpressions.Regex.IsMatch(HostKeyFingerprint.Trim(), "^SHA256:[A-Za-z0-9+/]{43}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            AddError(validationErrors, nameof(HostKeyFingerprint), "Use an OpenSSH SHA256 host-key fingerprint.");
        if (SshCredentialRef is not null && (!SshCredentialRef.StartsWith("secret://", StringComparison.Ordinal) || SshCredentialRef.Length <= "secret://".Length))
            AddError(validationErrors, nameof(SshCredentialRef), "SSH credentials must be referenced through a secret:// URI.");
        if (Sans is null || Sans.Length == 0 || Sans.Any(string.IsNullOrWhiteSpace))
            AddError(validationErrors, nameof(Sans), "At least one non-empty DNS name or IP SAN is required.");
        else if (Sans.Any(san => !IsDnsOrIp(san.Trim())))
            AddError(validationErrors, nameof(Sans), "Every SAN must be a DNS name or IP address.");

        ValidateLinuxPath(CertificatePath, nameof(CertificatePath), validationErrors);
        ValidateLinuxPath(ChainPath, nameof(ChainPath), validationErrors);
        ValidateLinuxPath(PrivateKeyPath, nameof(PrivateKeyPath), validationErrors);
        if (new[] { CertificatePath, ChainPath, PrivateKeyPath }.Where(path => !string.IsNullOrWhiteSpace(path)).Distinct(StringComparer.Ordinal).Count() != 3)
            AddError(validationErrors, nameof(CertificatePath), "Certificate, chain, and private-key paths must be distinct.");
        if (FileOwner is not null && !IsLinuxAccountName(FileOwner.Trim()))
            AddError(validationErrors, nameof(FileOwner), "File owner must be a Linux account name.");
        if (FileGroup is not null && !IsLinuxAccountName(FileGroup.Trim()))
            AddError(validationErrors, nameof(FileGroup), "File group must be a Linux group name.");
        if (FileMode is not null && !System.Text.RegularExpressions.Regex.IsMatch(FileMode.Trim(), "^0?[0-7]{3}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            AddError(validationErrors, nameof(FileMode), "File mode must be an octal permission such as 0640.");
        ValidateIdentifier(RemoteHelperId, nameof(RemoteHelperId), validationErrors);
        ValidateIdentifier(ReloadActionId, nameof(ReloadActionId), validationErrors);
        ValidateIdentifier(HealthCheckId, nameof(HealthCheckId), validationErrors);

        errors = validationErrors.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray());
        if (errors.Count > 0)
        {
            service = null;
            return false;
        }

        string[] sans = Sans!.Select(san => san.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        service = new ManagedService(
            Guid.NewGuid(), Name!.Trim(), Environment!.Trim(), Owner!.Trim(), Host!.Trim(), Port,
            HostKeyFingerprint!.Trim(), SshCredentialRef!.Trim(), ProfileId, sans,
            CertificatePath!.Trim(), ChainPath!.Trim(), PrivateKeyPath!.Trim(), FileOwner!.Trim(),
            FileGroup!.Trim(), FileMode!.Trim(), RemoteHelperId!.Trim(), ReloadActionId!.Trim(),
            HealthCheckId!.Trim(), true, now, now);
        return true;
    }

    private static void CheckRequired(string? value, string field, int maxLength, Dictionary<string, List<string>> errors)
    {
        if (string.IsNullOrWhiteSpace(value))
            AddError(errors, field, "This field is required.");
        else if (value.Trim().Length > maxLength)
            AddError(errors, field, $"This field must be at most {maxLength} characters.");
    }

    private static void ValidateLinuxPath(string? path, string field, Dictionary<string, List<string>> errors)
    {
        if (string.IsNullOrWhiteSpace(path))
            return;
        string candidate = path.Trim();
        if (!candidate.StartsWith('/') || candidate.Contains('\0') || candidate.Split('/').Any(segment => segment is "." or ".."))
            AddError(errors, field, "Use an absolute Linux path without dot-segments.");
    }

    private static bool IsDnsOrIp(string value)
    {
        if (System.Net.IPAddress.TryParse(value, out _))
            return true;
        string dnsName = value.StartsWith("*.", StringComparison.Ordinal) ? value[2..] : value;
        return Uri.CheckHostName(dnsName) == UriHostNameType.Dns;
    }

    private static bool IsLinuxAccountName(string value) =>
        System.Text.RegularExpressions.Regex.IsMatch(value, "^[a-z_][a-z0-9_-]{0,31}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static void ValidateIdentifier(string? value, string field, Dictionary<string, List<string>> errors)
    {
        if (value is not null && !System.Text.RegularExpressions.Regex.IsMatch(value.Trim(), "^[A-Za-z0-9._-]{1,64}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            AddError(errors, field, "Use a registered identifier containing only letters, digits, dot, underscore, or hyphen.");
    }

    private static void AddError(Dictionary<string, List<string>> errors, string field, string message)
    {
        if (!errors.TryGetValue(field, out List<string>? fieldErrors))
            errors[field] = fieldErrors = [];
        fieldErrors.Add(message);
    }
}

internal sealed record ManagedServiceResponse(
    Guid Id,
    string Name,
    string Environment,
    string Owner,
    string Host,
    int Port,
    string HostKeyFingerprint,
    string SshCredentialRef,
    Guid ProfileId,
    IReadOnlyList<string> Sans,
    string CertificatePath,
    string ChainPath,
    string PrivateKeyPath,
    string FileOwner,
    string FileGroup,
    string FileMode,
    string RemoteHelperId,
    string ReloadActionId,
    string HealthCheckId,
    bool Enabled,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public static ManagedServiceResponse From(ManagedService service) => new(
        service.Id, service.Name, service.Environment, service.Owner, service.Host, service.Port,
        service.HostKeyFingerprint, service.SshCredentialRef, service.ProfileId, service.Sans,
        service.CertificatePath, service.ChainPath, service.PrivateKeyPath, service.FileOwner,
        service.FileGroup, service.FileMode, service.RemoteHelperId, service.ReloadActionId,
        service.HealthCheckId, service.Enabled, service.CreatedAt, service.UpdatedAt);
}

internal sealed record CertificateJobResponse(
    Guid Id,
    Guid ServiceId,
    string RequestedBy,
    string State,
    long Version,
    Guid? CertificateId,
    string? CertificateFingerprint,
    DateTimeOffset CreatedAt,
    DateTimeOffset? FinishedAt,
    string? FailureStage,
    string? FailureSummary,
    IReadOnlyList<CertificateJobTransition> Transitions)
{
    public static CertificateJobResponse From(CertificateJob job) => new(
        job.Id, job.ServiceId, job.RequestedBy, job.State.ToString(), job.Version,
        job.CertificateId, job.CertificateFingerprint, job.CreatedAt, job.FinishedAt,
        job.FailureStage, job.FailureSummary, job.Transitions);
}
