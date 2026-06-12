namespace Pori.Services;

public interface IUnPrivOpService
{
    Task<OperationResult> GetFstabDashLAsync();
    
    Task<OperationResult> EscapeMountAsync(string mountPoint);
    
    Task<OperationResult> GetMountUnitInfoAsync(string unitName);
}