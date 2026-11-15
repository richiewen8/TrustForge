using System.Text.RegularExpressions;
using TrustForge.Core.Security;

namespace TrustForge.Api;

/// <summary>Development/deployment bridge for secret://env/NAME references; replace with a vault provider as needed.</summary>
public sealed partial class EnvironmentSecretResolver : ISecretResolver
{
    public ValueTask<string> ResolveAsync(string secretReference, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        const string filePrefix = "secret://file/";
        if (!string.IsNullOrWhiteSpace(secretReference) && secretReference.StartsWith(filePrefix, StringComparison.Ordinal))
        {
            string path = secretReference[filePrefix.Length..];
            if (!Path.IsPathFullyQualified(path))
                throw new InvalidOperationException("A secret file reference must contain an absolute path.");
            // Editors and shell redirects append trailing newlines; PEM, JSON, and token secrets have no meaningful trailing whitespace.
            return ValueTask.FromResult(File.ReadAllText(path).TrimEnd());
        }

        const string prefix = "secret://env/";
        if (string.IsNullOrWhiteSpace(secretReference) || !secretReference.StartsWith(prefix, StringComparison.Ordinal))
            throw new InvalidOperationException("This host resolves only secret://env/NAME references; configure a vault-backed ISecretResolver for other providers.");

        string variableName = secretReference[prefix.Length..];
        if (!EnvironmentVariableNameRegex().IsMatch(variableName))
            throw new InvalidOperationException("The secret reference contains an invalid environment variable name.");

        string value = Environment.GetEnvironmentVariable(variableName)
            ?? throw new InvalidOperationException($"The secret environment variable '{variableName}' is not configured.");
        return ValueTask.FromResult(value);
    }

    [GeneratedRegex("^[A-Za-z_][A-Za-z0-9_]*$", RegexOptions.CultureInvariant)]
    private static partial Regex EnvironmentVariableNameRegex();
}
