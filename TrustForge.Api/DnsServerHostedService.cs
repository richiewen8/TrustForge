using DnsServerCore;

namespace TrustForge.Api;

internal sealed class DnsServerHostedService(IConfiguration configuration, ILogger<DnsServerHostedService> logger) : IHostedService, IAsyncDisposable
{
    private DnsWebService? _dnsServer;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (!configuration.GetValue<bool>("DnsServer:Enabled"))
        {
            logger.LogInformation("Embedded DNS server is disabled.");
            return;
        }

        string configDirectory = configuration["DnsServer:ConfigDirectory"]
            ?? Path.Combine(AppContext.BaseDirectory, "dns-config");
        Uri updateCheckUri = new("https://go.technitium.com/?id=42");
        _dnsServer = new DnsWebService(isPortableApp: false, configDirectory, updateCheckUri);

        try
        {
            await _dnsServer.StartAsync(throwIfBindFails: true);
            logger.LogInformation("Embedded DNS server started with config directory {ConfigDirectory}.", configDirectory);
        }
        catch
        {
            await _dnsServer.DisposeAsync();
            _dnsServer = null;
            throw;
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_dnsServer is not null)
        {
            await _dnsServer.DisposeAsync();
            _dnsServer = null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_dnsServer is not null)
        {
            await _dnsServer.DisposeAsync();
            _dnsServer = null;
        }
    }
}
