using System.Diagnostics;

namespace WrongQuestionCapture.Windows;

internal sealed record WindowTarget(IntPtr Handle, uint ProcessId, string ProcessName, string WindowTitle)
{
    public string DisplayName => string.IsNullOrWhiteSpace(WindowTitle) ? ProcessName : $"{ProcessName} — {WindowTitle}";
}

internal sealed class WindowTargetService
{
    public WindowTarget? Current { get; private set; }

    public WindowTarget SelectCurrentForegroundWindow()
    {
        var handle = NativeMethods.GetForegroundWindow();
        if (handle == IntPtr.Zero || !NativeMethods.IsWindow(handle) || !NativeMethods.IsWindowVisible(handle))
            throw new InvalidOperationException("没有检测到可用的前台窗口。");

        NativeMethods.GetWindowThreadProcessId(handle, out var processId);
        if (processId == Environment.ProcessId)
            throw new InvalidOperationException("请先点击需要截取的题库窗口。");

        var buffer = new char[512];
        var length = NativeMethods.GetWindowText(handle, buffer, buffer.Length);
        var title = length > 0 ? new string(buffer, 0, length) : string.Empty;
        string processName;
        try { processName = Process.GetProcessById((int)processId).ProcessName; }
        catch { processName = "未知程序"; }

        Current = new WindowTarget(handle, processId, processName, title);
        return Current;
    }

    public void EnsureAvailable(WindowTarget target)
    {
        if (!NativeMethods.IsWindow(target.Handle))
        {
            Current = null;
            throw new InvalidOperationException("目标窗口已关闭，请重新选定。");
        }
        if (NativeMethods.IsIconic(target.Handle))
            throw new InvalidOperationException("目标窗口已最小化，请先恢复窗口。");
    }
}
