using System.Security.Cryptography.X509Certificates;

namespace TrustForge.Api;

internal static class SmallstepRootCertificate
{
    public static X509Certificate2 Load(string path)
    {
        // CreateFromPemFile fails on EC CA certificates in .NET 10 (it attempts private-key extraction); load the PEM text directly.
        X509Certificate2 root = X509Certificate2.CreateFromPem(File.ReadAllText(path));
        X509BasicConstraintsExtension? constraints = root.Extensions.OfType<X509BasicConstraintsExtension>().FirstOrDefault();
        if (constraints?.CertificateAuthority != true)
        {
            root.Dispose();
            throw new InvalidOperationException("SmallstepAcme:RootCertificatePath must point to a CA certificate.");
        }
        return root;
    }
}