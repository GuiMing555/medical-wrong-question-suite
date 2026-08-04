using System.ComponentModel;
using System.Diagnostics;

namespace WrongQuestionCapture.Windows;

internal sealed class TaskSchedulerService
{
    private const string TaskName = "医学综合练习_每日错题整理";

    public async Task SynchronizeAsync(bool enabled, string executablePath)
    {
        if (!OperatingSystem.IsWindows()) return;
        if (enabled)
        {
            var taskCommand = $"\"{executablePath}\" --organize-now";
            await RunAsync(["/Create", "/TN", TaskName, "/TR", taskCommand, "/SC", "DAILY", "/ST", "15:00", "/F", "/RL", "LIMITED"], false);
        }
        else
        {
            await RunAsync(["/Delete", "/TN", TaskName, "/F"], true);
        }
    }

    private static async Task RunAsync(IReadOnlyList<string> arguments, bool tolerateMissing)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "schtasks.exe"),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        using var process = new Process
        {
            StartInfo = startInfo
        };
        process.Start();
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var output = await outputTask;
        var error = await errorTask;
        if (process.ExitCode == 0 || tolerateMissing) return;
        throw new Win32Exception(process.ExitCode, "设置每日 15:00 整理任务失败：" + (string.IsNullOrWhiteSpace(error) ? output : error).Trim());
    }
}
