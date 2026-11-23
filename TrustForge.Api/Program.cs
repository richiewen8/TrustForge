using System.Security.Claims;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using TrustForge.Core.CertificateAlerts;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.DeploymentVersions;
using TrustForge.Core.ManagedServices;
using TrustForge.Core.Revocation;
using TrustForge.Core.Security;
using TrustForge.Persistence;
using TrustForge.Api;

WebApplicationBuilder builder = WebApplication.CreateBuilder(args);
string? connectionString = builder.Configuration.GetConnectionString("TrustForge");
if (string.IsNullOrWhiteSpace(connectionString))
    throw new InvalidOperationException("Configure ConnectionStrings:TrustForge using protected runtime configuration.");

builder.Services.AddTrustForgePersistence(connectionString);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<ISecretResolver, EnvironmentSecretResolver>();
builder.Services.Configure<SmallstepAcmeOptions>(builder.Configuration.GetSection("SmallstepAcme"));
builder.Services.AddScoped<ICertificateIssuer, SmallstepCertificateIssuer>();
builder.Services.Configure<TechnitiumDnsOptions>(builder.Configuration.GetSection("TechnitiumDns"));
builder.Services.AddHttpClient("TechnitiumDns", client => client.Timeout = TimeSpan.FromSeconds(15));
builder.Services.AddScoped<IDnsChallengeProvider, TechnitiumDnsChallengeProvider>();
builder.Services.AddScoped<ILinuxCertificateDeployer, SshLinuxCertificateDeployer>();
builder.Services.AddScoped<CertificateJobCoordinator>();
builder.Services.Configure<CertificateJobWorkerOptions>(builder.Configuration.GetSection("CertificateJobs:Worker"));
builder.Services.Configure<CertificateAlertOptions>(builder.Configuration.GetSection("CertificateJobs:Alerts"));
builder.Services.Configure<CertificateRenewalOptions>(builder.Configuration.GetSection("CertificateJobs:Renewal"));
builder.Services.Configure<CertificateExpiryOptions>(builder.Configuration.GetSection("CertificateJobs:Expiry"));
builder.Services.Configure<CertificateDeploymentOptions>(builder.Configuration.GetSection("CertificateJobs:Deployment"));
bool runMigrations = args.Contains("--migrate", StringComparer.Ordinal);
bool simulationEnabled = builder.Configuration.GetValue<bool>("CertificateJobs:Simulation:Enabled");
builder.Services.Configure<CertificateRevocationOptions>(builder.Configuration.GetSection("CertificateJobs:Revocation"));
builder.Services.AddScoped<ICertificateRevocationChannel, SmallstepCertificateRevoker>();
builder.Services.AddScoped<CertificateRevocationService>();
string artifactDirectory = builder.Configuration["CertificateJobs:Artifacts:Directory"]
    ?? "/var/lib/trustforge/artifacts";
if (!Path.IsPathFullyQualified(artifactDirectory))
    throw new InvalidOperationException("CertificateJobs:Artifacts:Directory must be an absolute path on the persistent application volume.");
// Revocation reads stored certificate material on the API request path, not only inside the worker.
builder.Services.AddSingleton<ICertificateArtifactStore>(new FileCertificateArtifactStore(artifactDirectory));
builder.Services.AddSingleton<IssuedCertificateValidator>();
if (!runMigrations && builder.Configuration.GetValue("CertificateJobs:Revocation:Enabled", true))
    builder.Services.AddHostedService<RevocationRetryWorker>();
if (simulationEnabled && !runMigrations)
{
    if (!builder.Environment.IsDevelopment())
        throw new InvalidOperationException("CertificateJobs:Simulation:Enabled is supported only in the Development environment.");
    builder.Services.AddScoped<ICertificateJobProcessor, DevelopmentCertificateJobProcessor>();
}
if ((builder.Configuration.GetValue<bool>("CertificateJobs:Worker:Enabled") || simulationEnabled) && !runMigrations)
{
    if (builder.Configuration.GetValue<bool>("CertificateJobs:Worker:Enabled") && !simulationEnabled)
    {
        builder.Services.AddScoped<ICertificateJobProcessor, CertificatePipelineProcessor>();
    }
    if (!builder.Services.Any(descriptor => descriptor.ServiceType == typeof(ICertificateJobProcessor)))
        throw new InvalidOperationException("The certificate job worker requires an ICertificateJobProcessor implementation.");
    builder.Services.AddHostedService<CertificateJobWorker>();
    builder.Services.AddHttpClient("CertificateAlerts", client => client.Timeout = TimeSpan.FromSeconds(15));
    builder.Services.AddScoped<ICertificateAlertSink, CertificateAlertSink>();
    builder.Services.AddHostedService<CertificateAlertDeliveryWorker>();
    builder.Services.AddHostedService<RenewalSchedulerWorker>();
    builder.Services.AddHostedService<ExpiryReminderWorker>();
}
builder.Services.AddHostedService<DnsServerHostedService>();

if (runMigrations)
{
    WebApplication migrationApp = builder.Build();
    await using AsyncServiceScope scope = migrationApp.Services.CreateAsyncScope();
    await scope.ServiceProvider.GetRequiredService<TrustForgeDatabaseMigrator>().ApplyAsync();
    return;
}

string? authority = builder.Configuration["Authentication:Authority"];
string? audience = builder.Configuration["Authentication:Audience"];
bool hasAuthorityUri = Uri.TryCreate(authority, UriKind.Absolute, out Uri? authorityUri);
bool allowInsecureLoopback = builder.Environment.IsDevelopment()
    && builder.Configuration.GetValue<bool>("Authentication:AllowInsecureLoopback")
    && hasAuthorityUri
    && authorityUri!.Scheme == Uri.UriSchemeHttp
    && authorityUri.IsLoopback;
if ((!hasAuthorityUri || authorityUri!.Scheme != Uri.UriSchemeHttps) && !allowInsecureLoopback
    || string.IsNullOrWhiteSpace(audience))
{
    throw new InvalidOperationException("Configure an HTTPS OIDC authority and audience. HTTP is allowed only for an explicitly enabled loopback issuer in Development.");
}

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = authority;
        options.Audience = audience;
        options.RequireHttpsMetadata = !allowInsecureLoopback;
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
    // Revocation is irreversible for a certificate, so it stays narrower than ordinary issuance rights.
    options.AddPolicy("CertificateRevoker", policy => policy.RequireRole("PlatformAdmin"));
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

api.MapPost("/services/{id:guid}/connection-test", async (
    Guid id,
    IManagedServiceStore services,
    ILinuxCertificateDeployer deployer,
    CancellationToken cancellationToken) =>
{
    ManagedService? service = await services.FindByIdAsync(id, cancellationToken);
    if (service is null)
        return Results.NotFound();

    try
    {
        // Connects with the pinned host key and runs the helper's validate operation; a fingerprint mismatch aborts before any remote operation.
        await deployer.ConnectAndValidateAsync(service, cancellationToken);
        return Results.Ok(new { success = true });
    }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
    {
        throw;
    }
    catch (Exception exception)
    {
        string message = exception.Message.Length <= 2048 ? exception.Message : exception.Message[..2048];
        return Results.Ok(new { success = false, error = message });
    }
})
.RequireAuthorization("CertificateOperator");

api.MapGet("/services/{id:guid}/deployment-versions", async (
    Guid id,
    int? limit,
    IManagedServiceStore services,
    IDeploymentVersionStore versions,
    CancellationToken cancellationToken) =>
{
    if (await services.FindByIdAsync(id, cancellationToken) is null)
        return Results.NotFound();
    IReadOnlyList<DeploymentVersion> items = await versions.ListByServiceAsync(id, limit ?? 50, cancellationToken);
    return Results.Ok(items.Select(DeploymentVersionResponse.From));
})
.RequireAuthorization("CertificateReader");

api.MapGet("/certificate-alerts", async (
    Guid? serviceId,
    string? deliveryState,
    int? limit,
    ICertificateAlertStore alerts,
    CancellationToken cancellationToken) =>
{
    CertificateAlertDeliveryState? state = null;
    if (deliveryState is not null)
    {
        if (!Enum.TryParse(deliveryState, ignoreCase: true, out CertificateAlertDeliveryState parsed))
            return Results.ValidationProblem(new Dictionary<string, string[]> { ["deliveryState"] = ["Use Pending, Delivered, or Failed."] });
        state = parsed;
    }
    IReadOnlyList<CertificateAlert> items = await alerts.ListAsync(serviceId, state, null, null, limit ?? 50, cancellationToken: cancellationToken);
    return Results.Ok(items.Select(CertificateAlertResponse.From));
})
.RequireAuthorization("CertificateReader");

api.MapGet("/audit/export", async (
    Guid? serviceId,
    DateTimeOffset? from,
    DateTimeOffset? to,
    int? limit,
    ICertificateJobStore jobs,
    IDeploymentVersionStore versions,
    ICertificateAlertStore alerts,
    ICertificateRevocationStore revocations,
    TimeProvider timeProvider,
    CancellationToken cancellationToken) =>
{
    if (from is not null && to is not null && from > to)
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["from"] = ["'from' must not be later than 'to'."] });

    int take = limit ?? 200;
    IReadOnlyList<CertificateJob> jobItems = await jobs.ListAsync(serviceId, from, to, take, cancellationToken);
    IReadOnlyList<DeploymentVersion> versionItems = await versions.ListAsync(serviceId, from, to, take, cancellationToken);
    IReadOnlyList<CertificateAlert> alertItems = await alerts.ListAsync(serviceId, null, from, to, take, cancellationToken);
    IReadOnlyList<CertificateRevocation> revocationItems = await revocations.ListAsync(serviceId, from, to, take, cancellationToken);
    var bundle = new
    {
        generatedAt = timeProvider.GetUtcNow(),
        filters = new { serviceId, from, to, limit = take },
        jobs = jobItems,
        deploymentVersions = versionItems,
        alerts = alertItems,
        revocations = revocationItems
    };
    return Results.Json(bundle, new JsonSerializerOptions(JsonSerializerDefaults.Web) { Converters = { new JsonStringEnumConverter() } });
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

    CertificateJob job;
    try
    {
        job = await coordinator.CreateManualJobAsync(id, subject, idempotencyKey, cancellationToken);
    }
    catch (CertificateJobActiveConflictException)
    {
        return Results.Conflict(new { error = "service_job_active" });
    }
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

api.MapPost("/services/{id:guid}/revocations", async (
    Guid id,
    HttpRequest request,
    CreateRevocationRequest body,
    ClaimsPrincipal principal,
    CertificateRevocationService revocations,
    CancellationToken cancellationToken) =>
{
    string? subject = principal.FindFirstValue("sub");
    if (string.IsNullOrWhiteSpace(subject))
        return Results.Forbid();

    string idempotencyKey = request.Headers["Idempotency-Key"].ToString();
    if (string.IsNullOrWhiteSpace(idempotencyKey) || idempotencyKey.Length > 200)
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["Idempotency-Key"] = ["A key between 1 and 200 characters is required."] });
    if (!Enum.TryParse(body.Reason, ignoreCase: false, out CertificateRevocationReason reason)
        || !Enum.IsDefined(reason))
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["reason"] = ["reason must be Unspecified, KeyCompromise, CaCompromise, AffiliationChanged, Superseded, or CessationOfOperation."] });

    RevocationResult result = await revocations.RequestAsync(id, reason, idempotencyKey.Trim(), subject, cancellationToken);
    // Only the outcomes that reached the CA must carry a record; the conflict outcomes below legitimately have none.
    if (result.Revocation is null && result.Status is not (RevocationStatus.ServiceNotFound or RevocationStatus.JobActive
            or RevocationStatus.NoActiveCertificate or RevocationStatus.CertificateMaterialMissing or RevocationStatus.FingerprintMismatch))
        return Results.Problem("The revocation record could not be read back after the CA attempt.");

    CertificateRevocationResponse? payload = result.Revocation is null ? null : CertificateRevocationResponse.From(result.Revocation);
    return result.Status switch
    {
        RevocationStatus.Revoked => Results.Ok(new { status = "revoked", revocation = payload }),
        RevocationStatus.Replayed => Results.Ok(new { status = "replayed", revocation = payload }),
        RevocationStatus.PendingRetry => Results.Accepted($"/api/v1/certificate-revocations/{result.Revocation!.Id}", new { status = "pending", revocation = payload }),
        RevocationStatus.ServiceNotFound => Results.NotFound(),
        RevocationStatus.JobActive => Results.Conflict(new { error = "service_job_active", jobId = result.Error }),
        RevocationStatus.NoActiveCertificate => Results.Conflict(new { error = "no_active_certificate" }),
        RevocationStatus.CertificateMaterialMissing => Results.Conflict(new { error = "certificate_material_missing" }),
        RevocationStatus.FingerprintMismatch => Results.Conflict(new { error = "certificate_fingerprint_mismatch" }),
        _ => Results.Problem("Unexpected revocation outcome.")
    };
})
.RequireAuthorization("CertificateRevoker");

api.MapGet("/services/{id:guid}/revocations", async (
    Guid id,
    int? limit,
    ICertificateRevocationStore revocations,
    CancellationToken cancellationToken) =>
{
    IReadOnlyList<CertificateRevocation> items = await revocations.ListAsync(id, null, null, limit ?? 50, cancellationToken);
    return Results.Ok(items.Select(CertificateRevocationResponse.From).ToArray());
})
.RequireAuthorization("CertificateReader");

api.MapGet("/certificate-revocations/{id:guid}", async (
    Guid id,
    ICertificateRevocationStore revocations,
    CancellationToken cancellationToken) =>
{
    CertificateRevocation? revocation = await revocations.FindByIdAsync(id, cancellationToken);
    return revocation is null ? Results.NotFound() : Results.Ok(CertificateRevocationResponse.From(revocation));
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
    string? HealthCheckId,
    bool? RenewalEnabled,
    string? RenewalLeadTime)
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
            AddError(validationErrors, nameof(FileMode), "File mode must be an octal permission such as 0600.");
        else if (FileMode is not null && ((Convert.ToInt32(FileMode.Trim(), 8) & ~0x180) != 0 || (Convert.ToInt32(FileMode.Trim(), 8) & 0x100) == 0))
            AddError(validationErrors, nameof(FileMode), "Private-key mode must grant owner read access only, such as 0400 or 0600.");
        ValidateIdentifier(RemoteHelperId, nameof(RemoteHelperId), validationErrors);
        if (RemoteHelperId is not null && !string.Equals(RemoteHelperId.Trim(), "trustforge-certctl-v1", StringComparison.Ordinal))
            AddError(validationErrors, nameof(RemoteHelperId), "Supported remote helper identifier is trustforge-certctl-v1.");
        ValidateIdentifier(ReloadActionId, nameof(ReloadActionId), validationErrors);
        ValidateIdentifier(HealthCheckId, nameof(HealthCheckId), validationErrors);

        TimeSpan renewalLeadTime = TimeSpan.FromDays(30);
        if (RenewalLeadTime is not null
            && (!TimeSpan.TryParse(RenewalLeadTime.Trim(), System.Globalization.CultureInfo.InvariantCulture, out renewalLeadTime)
                || renewalLeadTime <= TimeSpan.Zero || renewalLeadTime > TimeSpan.FromDays(365)))
            AddError(validationErrors, nameof(RenewalLeadTime), "Use a positive duration of at most 365 days, such as 30.00:00:00.");

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
            HealthCheckId!.Trim(), RenewalEnabled ?? false, renewalLeadTime, true, now, now);
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
    bool RenewalEnabled,
    TimeSpan RenewalLeadTime,
    bool Enabled,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public static ManagedServiceResponse From(ManagedService service) => new(
        service.Id, service.Name, service.Environment, service.Owner, service.Host, service.Port,
        service.HostKeyFingerprint, service.SshCredentialRef, service.ProfileId, service.Sans,
        service.CertificatePath, service.ChainPath, service.PrivateKeyPath, service.FileOwner,
        service.FileGroup, service.FileMode, service.RemoteHelperId, service.ReloadActionId,
        service.HealthCheckId, service.RenewalEnabled, service.RenewalLeadTime, service.Enabled, service.CreatedAt, service.UpdatedAt);
}

internal sealed record DeploymentVersionResponse(
    Guid Id,
    Guid ServiceId,
    Guid JobId,
    Guid? CertificateId,
    string Fingerprint,
    string ReleaseId,
    string? PreviousReleaseId,
    string Status,
    string HealthStatus,
    DateTimeOffset StagedAt,
    DateTimeOffset? ActivatedAt,
    DateTimeOffset? VerifiedAt,
    DateTimeOffset? CertificateNotAfter)
{
    public static DeploymentVersionResponse From(DeploymentVersion version) => new(
        version.Id, version.ServiceId, version.JobId, version.CertificateId, version.Fingerprint,
        version.ReleaseId, version.PreviousReleaseId, version.Status.ToString(), version.HealthStatus.ToString(),
        version.StagedAt, version.ActivatedAt, version.VerifiedAt, version.CertificateNotAfter);
}

internal sealed record CertificateAlertResponse(
    Guid Id,
    Guid? JobId,
    Guid ServiceId,
    string Kind,
    string Severity,
    string Stage,
    string Summary,
    DateTimeOffset OccurredAt,
    string DeliveryState,
    int AttemptCount,
    DateTimeOffset? NextAttemptAt,
    DateTimeOffset? DeliveredAt,
    string? LastError,
    string? DedupeKey)
{
    public static CertificateAlertResponse From(CertificateAlert alert) => new(
        alert.Id, alert.JobId, alert.ServiceId, alert.Kind.ToString(), alert.Severity.ToString(),
        alert.Stage, alert.Summary, alert.OccurredAt, alert.DeliveryState.ToString(),
        alert.AttemptCount, alert.NextAttemptAt, alert.DeliveredAt, alert.LastError, alert.DedupeKey);
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

internal sealed record CreateRevocationRequest(string Reason);

internal sealed record CertificateRevocationResponse(
    Guid Id,
    Guid ServiceId,
    Guid JobId,
    string Fingerprint,
    string Serial,
    string Reason,
    string State,
    string RequestedBy,
    string IdempotencyKey,
    DateTimeOffset RequestedAt,
    DateTimeOffset? RevokedAt,
    int AttemptCount,
    string? LastError)
{
    public static CertificateRevocationResponse From(CertificateRevocation revocation) => new(
        revocation.Id, revocation.ServiceId, revocation.JobId, revocation.Fingerprint, revocation.Serial,
        revocation.Reason.ToString(), revocation.State.ToString(), revocation.RequestedBy, revocation.IdempotencyKey,
        revocation.RequestedAt, revocation.RevokedAt, revocation.AttemptCount, revocation.LastError);
}
