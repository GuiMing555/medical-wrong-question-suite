using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WrongQuestionCapture.Windows;

internal sealed class GlobalShortcutService : IDisposable
{
    private readonly object _gate = new();
    private readonly HashSet<int> _keysDown = [];
    private readonly NativeMethods.LowLevelKeyboardProc _callback;
    private IntPtr _hook;
    private CaptureShortcut _captureShortcut;
    private bool _rightShiftWasUsedAsModifier;
    private DateTimeOffset _rightShiftPressedAt;

    public event Action? CaptureRequested;
    public event Action? TargetSelectionRequested;

    public GlobalShortcutService() => _callback = HookCallback;

    public void Start(CaptureShortcut captureShortcut)
    {
        lock (_gate)
        {
            _captureShortcut = captureShortcut;
            if (_hook != IntPtr.Zero) NativeMethods.UnhookWindowsHookEx(_hook);
            _hook = NativeMethods.SetWindowsHookEx(
                NativeMethods.WhKeyboardLl,
                _callback,
                NativeMethods.GetModuleHandle(null),
                0);
            if (_hook == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法注册全局截图快捷键。");
            _keysDown.Clear();
        }
    }

    private IntPtr HookCallback(int code, IntPtr message, IntPtr data)
    {
        if (code < 0) return NativeMethods.CallNextHookEx(_hook, code, message, data);
        var value = Marshal.PtrToStructure<NativeMethods.KbdLlHookStruct>(data);
        var key = (int)value.VirtualKeyCode;
        var isDown = message == (IntPtr)NativeMethods.WmKeyDown || message == (IntPtr)NativeMethods.WmSysKeyDown;
        var isUp = message == (IntPtr)NativeMethods.WmKeyUp || message == (IntPtr)NativeMethods.WmSysKeyUp;

        lock (_gate)
        {
            if (isDown)
            {
                var firstPress = _keysDown.Add(key);
                if (key == NativeMethods.VkRShift && firstPress)
                {
                    _rightShiftPressedAt = DateTimeOffset.UtcNow;
                    _rightShiftWasUsedAsModifier = false;
                }
                else if (_keysDown.Contains(NativeMethods.VkRShift))
                {
                    _rightShiftWasUsedAsModifier = true;
                }

                if (firstPress && IsTargetSelectionShortcut(key))
                {
                    _rightShiftWasUsedAsModifier = true;
                    TargetSelectionRequested?.Invoke();
                }
                else if (firstPress && _captureShortcut != CaptureShortcut.RightShift && IsConfiguredCaptureShortcut(key))
                {
                    CaptureRequested?.Invoke();
                }
            }
            else if (isUp)
            {
                _keysDown.Remove(key);
                if (key == NativeMethods.VkRShift && _captureShortcut == CaptureShortcut.RightShift)
                {
                    var duration = DateTimeOffset.UtcNow - _rightShiftPressedAt;
                    if (!_rightShiftWasUsedAsModifier && duration <= TimeSpan.FromMilliseconds(900))
                        CaptureRequested?.Invoke();
                    _rightShiftWasUsedAsModifier = false;
                }
            }
        }
        return NativeMethods.CallNextHookEx(_hook, code, message, data);
    }

    private static bool IsPressed(int key) => (NativeMethods.GetAsyncKeyState(key) & 0x8000) != 0;

    private static bool IsTargetSelectionShortcut(int key) =>
        key == NativeMethods.Vk1 && IsPressed(NativeMethods.VkControl) && IsPressed(NativeMethods.VkMenu) && IsPressed(NativeMethods.VkShift);

    private bool IsConfiguredCaptureShortcut(int key) => _captureShortcut switch
    {
        CaptureShortcut.ControlAltF12 => key == NativeMethods.VkF12 && IsPressed(NativeMethods.VkControl) && IsPressed(NativeMethods.VkMenu),
        CaptureShortcut.ControlShiftF12 => key == NativeMethods.VkF12 && IsPressed(NativeMethods.VkControl) && IsPressed(NativeMethods.VkShift),
        CaptureShortcut.ControlAltShiftS => key == NativeMethods.VkS && IsPressed(NativeMethods.VkControl) && IsPressed(NativeMethods.VkMenu) && IsPressed(NativeMethods.VkShift),
        _ => false
    };

    public void Dispose()
    {
        lock (_gate)
        {
            if (_hook == IntPtr.Zero) return;
            NativeMethods.UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
    }
}
