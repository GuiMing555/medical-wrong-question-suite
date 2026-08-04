using System.Text.Json;

namespace WrongQuestionCapture.Windows;

internal enum CaptureShortcut
{
    RightShift,
    ControlAltF12,
    ControlShiftF12,
    ControlAltShiftS
}

internal sealed record ShortcutChoice(CaptureShortcut Value, string Title)
{
    public override string ToString() => Title;

    public static IReadOnlyList<ShortcutChoice> All { get; } =
    [
        new(CaptureShortcut.RightShift, "单独轻点右 Shift（推荐）"),
        new(CaptureShortcut.ControlAltF12, "Ctrl + Alt + F12"),
        new(CaptureShortcut.ControlShiftF12, "Ctrl + Shift + F12"),
        new(CaptureShortcut.ControlAltShiftS, "Ctrl + Alt + Shift + S")
    ];
}

internal sealed class CaptureAppSettings
{
    public string CaptureFolderPath { get; set; } = DefaultCaptureFolder();
    public string OutputFolderPath { get; set; } = Path.Combine(DefaultCaptureFolder(), "错题本");
    public CaptureShortcut CaptureShortcut { get; set; } = CaptureShortcut.RightShift;
    public bool DailyOrganizeEnabled { get; set; } = true;

    public void ValidateAndCreateFolders()
    {
        if (string.IsNullOrWhiteSpace(CaptureFolderPath) || string.IsNullOrWhiteSpace(OutputFolderPath))
            throw new InvalidOperationException("截图和文档保存位置不能为空。");
        CaptureFolderPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(CaptureFolderPath.Trim()));
        OutputFolderPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(OutputFolderPath.Trim()));
        Directory.CreateDirectory(CaptureFolderPath);
        Directory.CreateDirectory(OutputFolderPath);
    }

    private static string DefaultCaptureFolder()
    {
        var pictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        return Path.Combine(pictures, "错题截图");
    }
}

internal sealed class SettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _settingsPath;

    public SettingsStore()
    {
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "医学综合练习");
        Directory.CreateDirectory(root);
        _settingsPath = Path.Combine(root, "capture-settings.json");
    }

    public CaptureAppSettings Load()
    {
        try
        {
            if (File.Exists(_settingsPath))
                return JsonSerializer.Deserialize<CaptureAppSettings>(File.ReadAllText(_settingsPath), JsonOptions) ?? new CaptureAppSettings();
        }
        catch (JsonException) { }
        return new CaptureAppSettings();
    }

    public void Save(CaptureAppSettings settings)
    {
        settings.ValidateAndCreateFolders();
        var temporary = _settingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(settings, JsonOptions));
        File.Move(temporary, _settingsPath, true);
    }
}
