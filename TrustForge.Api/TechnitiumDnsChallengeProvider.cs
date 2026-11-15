using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using TrustForge.Core.CertificateJobs;
using TrustForge.Core.ManagedServices;
using TrustForge.Core.Security;

namespace TrustForge.Api;

public sealed class TechnitiumDnsChallengeProvider(
    IHttpClientFactory httpClientFactory,
    ISecretResolver secretResolver,
    IOptions<TechnitiumDnsOptions> options) : IDnsChallengeProvider
{
    private readonly TechnitiumDnsOptions _options = options.Value;

    public async Task PresentAsync(Guid jobId, ManagedService service, Dns01Challenge challenge, CancellationToken cancellationToken = default)
    {
        (Uri baseUri, string apiToken) = await GetConfigurationAsync(cancellationToken);
        string zone = FindAllowedZone(challenge.RecordName);
        if (await HasTxtRecordAsync(baseUri, apiToken, challenge.RecordName, zone, challenge.TxtValue, cancellationToken))
            return;

        Dictionary<string, string> form = new(StringComparer.Ordinal)
        {
            ["domain"] = challenge.RecordName,
            ["zone"] = zone,
            ["type"] = "TXT",
            ["text"] = challenge.TxtValue,
            ["ttl"] = _options.RecordTtlSeconds.ToString(CultureInfo.InvariantCulture),
            ["expiryTtl"] = _options.RecordExpiryTtlSeconds.ToString(CultureInfo.InvariantCulture),
            ["comments"] = $"TrustForge ACME job {jobId:D}",
            ["overwrite"] = "false"
        };
        await SendApiAsync(baseUri, apiToken, "/api/zones/records/add", form, cancellationToken);
    }

    public async Task WaitForPropagationAsync(Dns01Challenge challenge, CancellationToken cancellationToken = default)
    {
        ValidateOptions();
        if (!IPAddress.TryParse(_options.ResolverAddress, out IPAddress? resolverAddress))
            throw new InvalidOperationException("TechnitiumDns:ResolverAddress must be an IPv4 or IPv6 address.");

        DateTimeOffset deadline = DateTimeOffset.UtcNow + _options.PropagationTimeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (await DnsTxtRecordExistsAsync(resolverAddress, _options.ResolverPort, challenge.RecordName, challenge.TxtValue, cancellationToken))
                return;
            await Task.Delay(_options.PollInterval, cancellationToken);
        }
        throw new TimeoutException($"DNS-01 TXT record '{challenge.RecordName}' did not become visible through the configured resolver.");
    }

    public async Task CleanupAsync(Guid jobId, ManagedService service, Dns01Challenge challenge, CancellationToken cancellationToken = default)
    {
        // PresentAsync rejects owners outside the allowed zones, so no record can exist there to clean up.
        string? zone = TryFindAllowedZone(challenge.RecordName);
        if (zone is null)
            return;
        (Uri baseUri, string apiToken) = await GetConfigurationAsync(cancellationToken);
        if (!await HasTxtRecordAsync(baseUri, apiToken, challenge.RecordName, zone, challenge.TxtValue, cancellationToken))
            return;

        Dictionary<string, string> form = new(StringComparer.Ordinal)
        {
            ["domain"] = challenge.RecordName,
            ["zone"] = zone,
            ["type"] = "TXT",
            ["characterStringsBase64"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(challenge.TxtValue))
        };
        await SendApiAsync(baseUri, apiToken, "/api/zones/records/delete", form, cancellationToken);
    }

    private async Task<(Uri BaseUri, string ApiToken)> GetConfigurationAsync(CancellationToken cancellationToken)
    {
        ValidateOptions();
        if (!Uri.TryCreate(_options.BaseUrl, UriKind.Absolute, out Uri? baseUri)
            || (baseUri.Scheme != Uri.UriSchemeHttps && !(baseUri.Scheme == Uri.UriSchemeHttp && baseUri.IsLoopback)))
            throw new InvalidOperationException("TechnitiumDns:BaseUrl must use HTTPS; loopback HTTP is allowed for the embedded local DNS API.");
        if (string.IsNullOrWhiteSpace(_options.ApiTokenSecretRef))
            throw new InvalidOperationException("Configure TechnitiumDns:ApiTokenSecretRef with a least-privilege API token reference.");
        string apiToken = await secretResolver.ResolveAsync(_options.ApiTokenSecretRef, cancellationToken);
        return (new Uri(baseUri.ToString().TrimEnd('/') + "/"), apiToken);
    }

    private void ValidateOptions()
    {
        if (_options.AllowedZones.Length == 0
            || _options.RecordTtlSeconds is < 1 or > 86400
            || _options.RecordExpiryTtlSeconds < _options.RecordTtlSeconds
            || _options.ResolverPort is < 1 or > 65535
            || _options.PropagationTimeout <= TimeSpan.Zero
            || _options.PollInterval <= TimeSpan.Zero)
            throw new InvalidOperationException("Technitium DNS allowed zones, TTL, resolver, and propagation settings are invalid.");
    }

    private string FindAllowedZone(string recordName) =>
        TryFindAllowedZone(recordName)
        ?? throw new InvalidOperationException($"The challenge owner '{NormalizeDnsName(recordName)}' is outside configured Technitium DNS zones.");

    private string? TryFindAllowedZone(string recordName)
    {
        string normalized = NormalizeDnsName(recordName);
        return _options.AllowedZones
            .Select(NormalizeDnsName)
            .Where(candidate => normalized == candidate || normalized.EndsWith("." + candidate, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(candidate => candidate.Length)
            .FirstOrDefault();
    }

    private async Task<bool> HasTxtRecordAsync(Uri baseUri, string apiToken, string recordName, string zone, string expectedValue, CancellationToken cancellationToken)
    {
        Dictionary<string, string> form = new(StringComparer.Ordinal)
        {
            ["domain"] = recordName,
            ["zone"] = zone,
            ["listZone"] = "false"
        };
        using HttpRequestMessage request = CreateApiRequest(baseUri, apiToken, "/api/zones/records/get", form);
        using HttpResponseMessage response = await httpClientFactory.CreateClient("TechnitiumDns").SendAsync(request, cancellationToken);
        using JsonDocument document = await EnsureApiSuccessAsync(response, cancellationToken);
        JsonElement records = document.RootElement.GetProperty("response").GetProperty("records");
        foreach (JsonElement record in records.EnumerateArray())
        {
            if (!record.TryGetProperty("type", out JsonElement type) || type.GetString() != "TXT"
                || !record.TryGetProperty("rData", out JsonElement rData))
                continue;
            if (rData.TryGetProperty("characterStringsBase64", out JsonElement encoded)
                && encoded.ValueKind == JsonValueKind.Array)
            {
                string value = string.Concat(encoded.EnumerateArray().Select(part => Encoding.UTF8.GetString(Convert.FromBase64String(part.GetString() ?? string.Empty))));
                if (value == expectedValue)
                    return true;
            }
            if (rData.TryGetProperty("text", out JsonElement text) && text.GetString() == expectedValue)
                return true;
        }
        return false;
    }

    private async Task SendApiAsync(Uri baseUri, string apiToken, string path, Dictionary<string, string> form, CancellationToken cancellationToken)
    {
        using HttpRequestMessage request = CreateApiRequest(baseUri, apiToken, path, form);
        using HttpResponseMessage response = await httpClientFactory.CreateClient("TechnitiumDns").SendAsync(request, cancellationToken);
        using JsonDocument document = await EnsureApiSuccessAsync(response, cancellationToken);
    }

    private static HttpRequestMessage CreateApiRequest(Uri baseUri, string apiToken, string path, Dictionary<string, string> form)
    {
        HttpRequestMessage request = new(HttpMethod.Post, new Uri(baseUri, path.TrimStart('/')))
        {
            Content = new FormUrlEncodedContent(form)
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiToken);
        return request;
    }

    private static async Task<JsonDocument> EnsureApiSuccessAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        response.EnsureSuccessStatusCode();
        // The buffered content stream is single-pass; parse once and hand the document to the caller.
        JsonDocument document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
        if (!document.RootElement.TryGetProperty("status", out JsonElement status) || status.GetString() != "ok")
        {
            document.Dispose();
            throw new InvalidOperationException("Technitium DNS API rejected the ACME TXT operation.");
        }
        return document;
    }

    private static string NormalizeDnsName(string name)
    {
        string trimmed = name.Trim().TrimEnd('.');
        return new IdnMapping().GetAscii(trimmed).ToLowerInvariant();
    }

    private static async Task<bool> DnsTxtRecordExistsAsync(IPAddress resolverAddress, int port, string domain, string expectedValue, CancellationToken cancellationToken)
    {
        using UdpClient client = new(resolverAddress.AddressFamily);
        byte[] query = BuildTxtQuery(domain, out ushort id);
        IPEndPoint endpoint = new(resolverAddress, port);
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        await client.SendAsync(query, endpoint, timeout.Token);
        UdpReceiveResult response;
        try
        {
            response = await client.ReceiveAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        if (!response.RemoteEndPoint.Equals(endpoint))
            return false;
        return ParseTxtResponse(response.Buffer, id, expectedValue);
    }

    private static byte[] BuildTxtQuery(string domain, out ushort id)
    {
        id = (ushort)Random.Shared.Next(ushort.MaxValue + 1);
        using MemoryStream stream = new();
        using BinaryWriter writer = new(stream, Encoding.ASCII, leaveOpen: true);
        writer.Write((byte)(id >> 8)); writer.Write((byte)id);
        writer.Write((byte)0x01); writer.Write((byte)0x00); // standard query, recursion desired
        writer.Write((byte)0); writer.Write((byte)1); // QDCOUNT
        writer.Write((byte)0); writer.Write((byte)0); // ANCOUNT
        writer.Write((byte)0); writer.Write((byte)0); // NSCOUNT
        writer.Write((byte)0); writer.Write((byte)0); // ARCOUNT
        foreach (string label in new IdnMapping().GetAscii(domain.TrimEnd('.')).Split('.'))
        {
            byte[] bytes = Encoding.ASCII.GetBytes(label);
            if (bytes.Length is < 1 or > 63)
                throw new InvalidOperationException("The DNS challenge owner contains an invalid label.");
            writer.Write((byte)bytes.Length);
            writer.Write(bytes);
        }
        writer.Write((byte)0);
        writer.Write((byte)0); writer.Write((byte)16); // TXT
        writer.Write((byte)0); writer.Write((byte)1); // IN
        return stream.ToArray();
    }

    private static bool ParseTxtResponse(byte[] response, ushort expectedId, string expectedValue)
    {
        if (response.Length < 12 || ReadUInt16(response, 0) != expectedId)
            return false;
        ushort flags = ReadUInt16(response, 2);
        if ((flags & 0x8000) == 0 || (flags & 0x000F) != 0)
            return false;
        int questionCount = ReadUInt16(response, 4);
        int answerCount = ReadUInt16(response, 6);
        int offset = 12;
        for (int index = 0; index < questionCount; index++)
        {
            offset = SkipName(response, offset);
            offset += 4;
        }
        for (int index = 0; index < answerCount; index++)
        {
            offset = SkipName(response, offset);
            if (offset + 10 > response.Length)
                return false;
            ushort type = ReadUInt16(response, offset);
            ushort classCode = ReadUInt16(response, offset + 2);
            ushort length = ReadUInt16(response, offset + 8);
            offset += 10;
            if (offset + length > response.Length)
                return false;
            if (type == 16 && classCode == 1)
            {
                int end = offset + length;
                int dataOffset = offset;
                StringBuilder value = new();
                while (dataOffset < end)
                {
                    int segmentLength = response[dataOffset++];
                    if (dataOffset + segmentLength > end)
                        return false;
                    value.Append(Encoding.UTF8.GetString(response, dataOffset, segmentLength));
                    dataOffset += segmentLength;
                }
                if (value.ToString() == expectedValue)
                    return true;
            }
            offset += length;
        }
        return false;
    }

    private static int SkipName(byte[] message, int offset)
    {
        while (offset < message.Length)
        {
            byte length = message[offset++];
            if (length == 0)
                return offset;
            if ((length & 0xC0) == 0xC0)
            {
                if (offset >= message.Length)
                    throw new InvalidDataException("Malformed compressed DNS name.");
                return offset + 1;
            }
            offset += length;
        }
        throw new InvalidDataException("Malformed DNS name in response.");
    }

    private static ushort ReadUInt16(byte[] data, int offset) => (ushort)((data[offset] << 8) | data[offset + 1]);
}
