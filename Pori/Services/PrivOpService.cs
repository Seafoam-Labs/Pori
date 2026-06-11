using System.Diagnostics;
using System.Text;

namespace Pori.Services;

public class PrivOpService(ICredentialManager credentialManager, IUnPrivOpService unPrivOpService) : IPrivOpService
{
    public async Task<bool> MountDrives(string unitName)
    {
        var result = await ExecutePrivilegedCommandAsync("systemctl", ["daemon-reload"]);
        var result2 = await ExecutePrivilegedCommandAsync("systemctl", ["enable", "--now", unitName]);

        return result.Success && result2.Success;
    }

    public async Task<OperationResult> CreateMountUnitFileAsync(string description, string uuid, string mountPoint,
        string fsType, string options)
    {
        var unitName = mountPoint.Trim('/').Replace('/', '-') + ".mount";
        var unitFilePath = $"/etc/systemd/system/{unitName}";

        var mountPointEscaped = await unPrivOpService.EscapeMountAsync(mountPoint);
        if (!mountPointEscaped.Success)
            return new OperationResult
            {
                Error = "failed to escape mount",
                ExitCode = 1,
                Success = false
            };


        var unitContent = "[Unit]\n"
                          + $"Description={description}\n"
                          + "\n"
                          + "[Mount]\n"
                          + $"What=/dev/disk/by-uuid/{uuid}\n"
                          + $"Where={mountPointEscaped.Output}\n"
                          + $"Type={fsType}\n"
                          + $"Options={options}\n"
                          + "\n"
                          + "[Install]\n"
                          + "WantedBy=multi-user.target\n";

        var tempFile = Path.GetTempFileName();
        try
        {
            await File.WriteAllTextAsync(tempFile, unitContent);
            return await ExecutePrivilegedCommandAsync("cp", [tempFile, unitFilePath]);
        }
        finally
        {
            if (File.Exists(tempFile))
                File.Delete(tempFile);
        }
    }

    private async Task<OperationResult> ExecutePrivilegedCommandAsync(string command, string[] args)
    {
        return await ExecutePrivilegedCommandAsync(command, inputData: null, args: args);
    }

    private async Task<OperationResult> ExecutePrivilegedCommandAsync(string command, string? inputData,
        params string[] args)
    {
        // Request credentials if not already available
        var hasCredentials = await credentialManager.RequestCredentialsAsync(command);
        if (!hasCredentials)
        {
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = "Authentication cancelled by user.",
                ExitCode = -1
            };
        }

        var password = credentialManager.GetPassword();
        if (string.IsNullOrEmpty(password))
        {
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = "No password available.",
                ExitCode = -1
            };
        }

        var arguments = string.Join(" ", args);
        var fullCommand = $"{command} {arguments}";

        Console.WriteLine($"Executing privileged command: sudo {fullCommand}");
        var isPasswordless = password == "NOPASSWORD67";
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "sudo",
                Arguments = isPasswordless ? fullCommand : $"-S -p \"\" {fullCommand}",
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

        // Semaphore + counter to prevent stdin from closing before async callbacks complete
        var stdinLock = new SemaphoreSlim(1, 1);
        bool stdinClosed = false;
        int pendingCallbacks = 0;
        var allCallbacksDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        // Helper to safely write to stdin
        async Task SafeWriteAsync(string value)
        {
            await stdinLock.WaitAsync();
            try
            {
                if (!stdinClosed && stdinWriter != null)
                {
                    await stdinWriter.WriteLineAsync(value);
                    await stdinWriter.FlushAsync();
                }
            }
            catch (ObjectDisposedException)
            {
            }
            finally
            {
                stdinLock.Release();
            }
        }

        process.OutputDataReceived += (sender, e) =>
        {
            if (e.Data != null)
            {
                outputBuilder.AppendLine(e.Data);
                Console.WriteLine(e.Data);
            }
        };

        process.ErrorDataReceived += (sender, e) =>
        {
            if (e.Data != null)
            {
                errorBuilder.AppendLine(e.Data);
                Console.Error.WriteLine(e.Data);
            }
        };

        try
        {
            process.Start();
            stdinWriter = process.StandardInput;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();


            if (!isPasswordless)
            {
                await stdinWriter.WriteLineAsync(password);
                await stdinWriter.FlushAsync();
            }

            // If there's input data to pipe (e.g. file content for tee), write it after password
            if (inputData != null)
            {
                await stdinWriter.WriteAsync(inputData);
                await stdinWriter.FlushAsync();
                stdinWriter.Close();
            }

            await process.WaitForExitAsync();

            // Wait for any in-flight async callbacks to finish writing
            if (Volatile.Read(ref pendingCallbacks) > 0)
            {
                await Task.WhenAny(allCallbacksDone.Task, Task.Delay(TimeSpan.FromMinutes(2)));
            }


            await stdinLock.WaitAsync();
            try
            {
                stdinClosed = true;
                stdinWriter?.Close();
            }
            finally
            {
                stdinLock.Release();
            }

            var success = process.ExitCode == 0;

            // Update credential validation status based on result
            if (success)
            {
                credentialManager.MarkAsValidated();
            }
            else
            {
                // Check if it was an authentication failure
                var errorOutput = errorBuilder.ToString();
                if (errorOutput.Contains("incorrect password") ||
                    errorOutput.Contains("Sorry, try again") ||
                    errorOutput.Contains("Authentication failure") ||
                    process.ExitCode == 1 && errorOutput.Contains("sudo"))
                {
                    credentialManager.MarkAsInvalid();
                }
            }

            return new OperationResult
            {
                Success = success,
                Output = outputBuilder.ToString(),
                Error = errorBuilder.ToString(),
                ExitCode = process.ExitCode,
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