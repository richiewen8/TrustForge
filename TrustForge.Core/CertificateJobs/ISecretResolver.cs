namespace TrustForge.Core.Security;

/// <summary>Resolves an opaque secret reference without exposing secret values to persistence or logs.</summary>
public interface ISecretResolver
{
    ValueTask<string> ResolveAsync(string secretReference, CancellationToken cancellationToken = default);
}
