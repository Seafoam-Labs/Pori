using System.Diagnostics;
using System.Text;

namespace Pori.Services;

public class UnPrivOpService : IUnPrivOpService
{
    public async Task<OperationResult> GetFstabDashLAsync()
    {
        return await ExecuteUnprivilegedCommandAsync("lsblk", "-f");
    }
    
   
    
    private async Task<OperationResult> ExecuteUnprivilegedCommandAsync(string command,
        params string[] args)
    {
        return await ExecuteUnprivilegedCommandAsync(command, CancellationToken.None, args);
    }

    private async Task<OperationResult> ExecuteUnprivilegedCommandAsync(string command,
        CancellationToken ct, params string[] args)
    {
        var arguments = string.Join(" ", args);
        var fullCommand = $"{command} {arguments}";

        Console.WriteLine($"Executing command: {fullCommand}");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = command,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true
            }
        };

        var outputBuilder = new StringBuilder();
        var errorBuilder = new StringBuilder();
        StreamWriter? stdinWriter = null;

        process.OutputDataReceived += (sender, e) =>
        {
            if (e.Data == null) return;
            outputBuilder.AppendLine(e.Data);
            Console.WriteLine(e.Data);
        };

        process.ErrorDataReceived += async (sender, e) =>
        {
            if (e.Data == null) return;
            errorBuilder.AppendLine(e.Data);
            await Console.Error.WriteLineAsync(e.Data);
        };

        try
        {
            process.Start();
            stdinWriter = process.StandardInput;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            try
            {
                await process.WaitForExitAsync(ct);
            }
            catch (OperationCanceledException)
            {
                if (!process.HasExited)
                    process.Kill(true);
                throw;
            }

            stdinWriter?.Close();

            var success = process.ExitCode == 0;

            return new OperationResult
            {
                Success = success,
                Output = outputBuilder.ToString(),
                Error = errorBuilder.ToString(),
                ExitCode = process.ExitCode
            };
        }
        catch (Exception ex)
        {
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = ex.Message,
                ExitCode = -1
            };
        }
    }
}