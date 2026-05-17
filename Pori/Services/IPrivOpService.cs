namespace Pori.Services;

public interface IPrivOpService
{
    Task<bool> MountDrives(string unitName);
    Task<OperationResult> CreateMountUnitFileAsync(string description, string uuid, string mountPoint, string fsType, string options);
}

public class OperationResult
{
    public bool Success { get; init; }
    public string Output { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public int ExitCode { get; init; }
}