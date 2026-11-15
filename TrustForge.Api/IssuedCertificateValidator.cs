using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.ManagedServices;

namespace TrustForge.Api;

/// <summary>Rejects issued material that does not match the service registration before anything is persisted or deployed.</summary>
public sealed class IssuedCertificateValidator(IOptions<SmallstepAcmeOptions> options)
{
    private const string ServerAuthenticationOid = "1.3.6.1.5.5.7.3.1";
    private static readonly TimeSpan ClockSkew = TimeSpan.FromMinutes(5);
    private readonly SmallstepAcmeOptions _options = options.Value;

    public void ValidateCsr(string csrPem, ManagedService service)
    {
        CertificateRequest csr = LoadCsr(csrPem);
        ValidateSans(EnumerateDnsNames(csr.CertificateExtensions), service);
        ValidateKeyStrength(csr.PublicKey);
    }

    public void Validate(IssuedCertificateBundle bundle, string csrPem, ManagedService service)
    {
        if (string.IsNullOrWhiteSpace(_options.RootCertificatePath))
            throw new InvalidOperationException("Configure SmallstepAcme:RootCertificatePath so issued certificates can be validated against the CA root.");
        using X509Certificate2 root = SmallstepRootCertificate.Load(_options.RootCertificatePath);
        using X509Certificate2 leaf = X509Certificate2.CreateFromPem(bundle.LeafCertificatePem);

        string fingerprint = Convert.ToHexString(leaf.GetCertHash(HashAlgorithmName.SHA256));
        if (!string.Equals(fingerprint, bundle.FingerprintSha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The issued leaf certificate fingerprint does not match the signing result.");

        ValidateChain(leaf, bundle.ChainPem, root);

        CertificateRequest csr = LoadCsr(csrPem);
        if (!csr.PublicKey.ExportSubjectPublicKeyInfo().AsSpan().SequenceEqual(leaf.PublicKey.ExportSubjectPublicKeyInfo()))
            throw new InvalidOperationException("The issued certificate public key does not match the target-generated CSR.");

        ValidateSans(EnumerateDnsNames(leaf.Extensions), service);
        ValidateKeyUsage(leaf);
        ValidateKeyStrength(leaf.PublicKey);
        ValidateValidity(leaf);
    }

    private static CertificateRequest LoadCsr(string csrPem)
    {
        try
        {
            // Default options drop CSR extensions; UnsafeLoadCertificateExtensions still validates the self-signature.
            return CertificateRequest.LoadSigningRequestPem(csrPem, default, CertificateRequestLoadOptions.UnsafeLoadCertificateExtensions, RSASignaturePadding.Pkcs1);
        }
        catch (CryptographicException exception)
        {
            throw new InvalidOperationException("The target-generated CSR is malformed or its self-signature is invalid.", exception);
        }
    }

    private static IEnumerable<string> EnumerateDnsNames(IEnumerable<X509Extension> extensions)
    {
        foreach (X509Extension extension in extensions)
            if (extension is X509SubjectAlternativeNameExtension san)
                foreach (string name in san.EnumerateDnsNames())
                    yield return name;
    }

    private static void ValidateSans(IEnumerable<string> actualSans, ManagedService service)
    {
        HashSet<string> expected = service.Sans.Select(NormalizeName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        HashSet<string> actual = actualSans.Select(NormalizeName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!expected.SetEquals(actual))
            throw new InvalidOperationException("The certificate SANs do not exactly match the registered service SANs.");
    }

    private static string NormalizeName(string name) => name.Trim().TrimEnd('.');

    private static void ValidateChain(X509Certificate2 leaf, string chainPem, X509Certificate2 root)
    {
        X509Certificate2Collection chainCertificates = new();
        chainCertificates.ImportFromPem(chainPem);
        try
        {
            using X509Chain chain = new();
            chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
            chain.ChainPolicy.CustomTrustStore.Add(root);
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            foreach (X509Certificate2 certificate in chainCertificates)
                chain.ChainPolicy.ExtraStore.Add(certificate);
            if (!chain.Build(leaf))
                throw new InvalidOperationException("The issued certificate chain does not validate against the configured Smallstep root.");
        }
        finally
        {
            foreach (X509Certificate2 certificate in chainCertificates)
                certificate.Dispose();
        }
    }

    private static void ValidateKeyUsage(X509Certificate2 leaf)
    {
        X509EnhancedKeyUsageExtension? eku = leaf.Extensions.OfType<X509EnhancedKeyUsageExtension>().FirstOrDefault();
        if (eku is null || !eku.EnhancedKeyUsages.Cast<Oid>().Any(oid => oid.Value == ServerAuthenticationOid))
            throw new InvalidOperationException("The issued certificate does not permit TLS server authentication.");
        X509KeyUsageExtension? keyUsage = leaf.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault();
        if (keyUsage is not null && (keyUsage.KeyUsages & X509KeyUsageFlags.DigitalSignature) == 0)
            throw new InvalidOperationException("The issued certificate key usage does not include digitalSignature.");
        X509BasicConstraintsExtension? constraints = leaf.Extensions.OfType<X509BasicConstraintsExtension>().FirstOrDefault();
        if (constraints?.CertificateAuthority == true)
            throw new InvalidOperationException("The issued leaf certificate must not be a CA certificate.");
    }

    private static void ValidateKeyStrength(PublicKey publicKey)
    {
        using RSA? rsa = publicKey.GetRSAPublicKey();
        if (rsa is not null)
        {
            if (rsa.KeySize < 3072)
                throw new InvalidOperationException("The certificate RSA key must be at least 3072 bits.");
            return;
        }
        using ECDsa? ecdsa = publicKey.GetECDsaPublicKey();
        if (ecdsa is not null)
        {
            ECCurve curve = ecdsa.ExportParameters(false).Curve;
            string[] allowedCurves =
            [
                ECCurve.NamedCurves.nistP256.Oid?.Value ?? string.Empty,
                ECCurve.NamedCurves.nistP384.Oid?.Value ?? string.Empty,
                ECCurve.NamedCurves.nistP521.Oid?.Value ?? string.Empty
            ];
            if (!curve.IsNamed || !allowedCurves.Contains(curve.Oid?.Value))
                throw new InvalidOperationException("The certificate ECDSA key must use nistP256, nistP384, or nistP521.");
            return;
        }
        throw new InvalidOperationException("The certificate key algorithm is unsupported; use RSA or ECDSA.");
    }

    private void ValidateValidity(X509Certificate2 leaf)
    {
        DateTimeOffset notBefore = new(leaf.NotBefore.ToUniversalTime());
        DateTimeOffset notAfter = new(leaf.NotAfter.ToUniversalTime());
        DateTimeOffset now = DateTimeOffset.UtcNow;
        if (notBefore > now + ClockSkew || notAfter <= now)
            throw new InvalidOperationException("The issued certificate is not currently valid.");
        if (notAfter - notBefore > _options.MaximumCertificateLifetime)
            throw new InvalidOperationException("The issued certificate lifetime exceeds SmallstepAcme:MaximumCertificateLifetime.");
    }
}