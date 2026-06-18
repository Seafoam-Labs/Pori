namespace Pori.Services;

public interface IPrivOpService
{
    Task<bool> MountDrives(string unitName);
    Task<OperationResult> CreateMountUnitFileAsync(string description, string uuid, string mountPoint, string fsType, string options);
    Task<OperationResult> EditMountUnitFileAsync(string oldUnitName, string description, string mountPoint, string fsType, string options);
    Task<OperationResult> DeleteMountUnitAsync(string mountUnitName);
    Task<OperationResult> GetMountUnitCatAsync(string unitName);
}

public class OperationResult
{
    public bool Success { get; init; }
    public string Output { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public int ExitCode { get; init; }
}