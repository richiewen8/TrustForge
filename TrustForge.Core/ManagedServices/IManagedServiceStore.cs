namespace TrustForge.Core.ManagedServices;

public interface IManagedServiceStore
{
    Task<bool> TryAddAsync(ManagedService service, CancellationToken cancellationToken = default);
    Task<ManagedService?> FindByIdAsync(Guid id, CancellationToken cancellationToken = default);
}
