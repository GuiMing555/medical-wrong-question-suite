using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Windows;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;

namespace WrongQuestionCapture.Windows;

public partial class MainWindow : Window
{
    private readonly AppHost _host;
    private readonly GlobalShortcutService _shortcuts = new();
    private readonly SemaphoreSlim _captureLock = new(1, 1);
    private readonly WinForms.NotifyIcon _trayIcon;
    private CaptureAppSettings _settings;
    private bool _allowClose;
    private bool _organizerRunning;

    public MainWindow(AppHost host)
    {
        InitializeComponent();
        _host = host;
        _settings = host.SettingsStore.Load();
        ShortcutComboBox.ItemsSource = ShortcutChoice.All;
        LoadSettingsIntoControls();

        _trayIcon = new WinForms.NotifyIcon
        {
            Text = "医学综合错题截图",
            Icon = SystemIcons.Application,
            Visible = true,
            ContextMenuStrip = BuildTrayMenu()
        };
        _trayIcon.DoubleClick += (_, _) => ShowSettingsWindow();

        _shortcuts.CaptureRequested += () => Dispatcher.BeginInvoke(new Action(CaptureSelectedWindowAsync));
        _shortcuts.TargetSelectionRequested += () => Dispatcher.BeginInvoke(new Action(SelectForegroundFromShortcut));
        Loaded += MainWindow_Loaded;
        Closing += MainWindow_Closing;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _shortcuts.Start(_settings.CaptureShortcut);
            await SynchronizeScheduleAsync(showSuccess: false);
        }
        catch (Exception ex)
        {
            SetStatus("初始化提示：" + ex.Message);
        }
    }

    private WinForms.ContextMenuStrip BuildTrayMenu()
    {
        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("打开设置", null, (_, _) => Dispatcher.BeginInvoke(new Action(ShowSettingsWindow)));
        menu.Items.Add("截图目标窗口", null, (_, _) => Dispatcher.BeginInvoke(new Action(CaptureSelectedWindowAsync)));
        menu.Items.Add("立即整理", null, (_, _) => Dispatcher.BeginInvoke(new Action(async () => await RunOrganizerAsync())));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Dispatcher.BeginInvoke(new Action(ExitApplication)));
        return menu;
    }

    private void LoadSettingsIntoControls()
    {
        CaptureFolderTextBox.Text = _settings.CaptureFolderPath;
        OutputFolderTextBox.Text = _settings.OutputFolderPath;
        DailyOrganizeCheckBox.IsChecked = _settings.DailyOrganizeEnabled;
        ShortcutComboBox.SelectedItem = ShortcutChoice.All.First(value => value.Value == _settings.CaptureShortcut);
    }

    private void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (_allowClose) return;
        e.Cancel = true;
        Hide();
        _trayIcon.ShowBalloonTip(1500, "医学综合错题截图", "程序仍在后台监听截图快捷键。", WinForms.ToolTipIcon.Info);
    }

    private void ShowSettingsWindow()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private void ExitApplication()
    {
        _allowClose = true;
        _shortcuts.Dispose();
        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        Close();
        System.Windows.Application.Current.Shutdown();
    }

    private async void SelectTargetButton_Click(object sender, RoutedEventArgs e)
    {
        SelectTargetButton.IsEnabled = false;
        SetStatus("3 秒内点击需要截图的题库窗口……");
        Hide();
        await Task.Delay(TimeSpan.FromSeconds(3));
        SelectForegroundFromShortcut();
        SelectTargetButton.IsEnabled = true;
    }

    private void SelectForegroundFromShortcut()
    {
        try
        {
            var target = _host.WindowTarget.SelectCurrentForegroundWindow();
            TargetStatusText.Text = "已选定：" + target.DisplayName;
            SetStatus("目标窗口已记录，可使用截图快捷键。");
            _trayIcon.ShowBalloonTip(1200, "目标窗口已记录", target.DisplayName, WinForms.ToolTipIcon.Info);
        }
        catch (Exception ex)
        {
            SetStatus("无法选定窗口：" + ex.Message);
        }
    }

    private async void CaptureNowButton_Click(object sender, RoutedEventArgs e) => await CaptureSelectedWindowAsync();

    private async void CaptureSelectedWindowAsync()
    {
        if (!await _captureLock.WaitAsync(0)) return;
        try
        {
            var target = _host.WindowTarget.Current ?? throw new InvalidOperationException("请先选定题库窗口。");
            _settings.ValidateAndCreateFolders();
            SetStatus("正在截取“" + target.DisplayName + "”……");
            var capture = await Task.Run(() => _host.WindowCapture.Capture(target, _settings.CaptureFolderPath));
            SetStatus("已保存 " + Path.GetFileName(capture.FilePath) + "，正在本机识别并同步错题本……");
            var report = await _host.Organizer.OrganizeAsync();
            SetStatus(report.Summary);
            _trayIcon.ShowBalloonTip(1800, "错题截图已处理", report.ShortSummary, WinForms.ToolTipIcon.Info);
        }
        catch (Exception ex)
        {
            SetStatus("截图失败：" + ex.Message);
            _trayIcon.ShowBalloonTip(2200, "截图失败", ex.Message, WinForms.ToolTipIcon.Error);
        }
        finally
        {
            _captureLock.Release();
        }
    }

    private void BrowseCaptureFolder_Click(object sender, RoutedEventArgs e) => BrowseFolder(CaptureFolderTextBox);
    private void BrowseOutputFolder_Click(object sender, RoutedEventArgs e) => BrowseFolder(OutputFolderTextBox);

    private void BrowseFolder(System.Windows.Controls.TextBox target)
    {
        var dialog = new OpenFolderDialog { InitialDirectory = Directory.Exists(target.Text) ? target.Text : null };
        if (dialog.ShowDialog(this) == true) target.Text = dialog.FolderName;
    }

    private async void SaveSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            _settings = new CaptureAppSettings
            {
                CaptureFolderPath = CaptureFolderTextBox.Text,
                OutputFolderPath = OutputFolderTextBox.Text,
                CaptureShortcut = ((ShortcutChoice?)ShortcutComboBox.SelectedItem)?.Value ?? CaptureShortcut.RightShift,
                DailyOrganizeEnabled = DailyOrganizeCheckBox.IsChecked == true
            };
            _host.SettingsStore.Save(_settings);
            _shortcuts.Start(_settings.CaptureShortcut);
            await SynchronizeScheduleAsync(showSuccess: true);
        }
        catch (Exception ex)
        {
            SetStatus("保存设置失败：" + ex.Message);
        }
    }

    private async Task SynchronizeScheduleAsync(bool showSuccess)
    {
        var executablePath = Environment.ProcessPath ?? throw new InvalidOperationException("无法确定程序路径。");
        await _host.Scheduler.SynchronizeAsync(_settings.DailyOrganizeEnabled, executablePath);
        if (showSuccess) SetStatus("设置已保存，每日 15:00 任务状态已同步。");
    }

    private async void OrganizeNowButton_Click(object sender, RoutedEventArgs e) => await RunOrganizerAsync();
    internal async void RunOrganizerFromExternalRequest() => await RunOrganizerAsync();

    private async Task RunOrganizerAsync()
    {
        if (_organizerRunning) return;
        _organizerRunning = true;
        try
        {
            SetStatus("正在本机识别、查重、同步题库并生成文档……");
            var report = await _host.Organizer.OrganizeAsync();
            SetStatus(report.Summary);
        }
        catch (Exception ex)
        {
            SetStatus("整理失败：" + ex.Message);
        }
        finally
        {
            _organizerRunning = false;
        }
    }

    private void OpenCaptureFolderButton_Click(object sender, RoutedEventArgs e) => OpenFolder(CaptureFolderTextBox.Text);
    private void OpenOutputFolderButton_Click(object sender, RoutedEventArgs e) => OpenFolder(OutputFolderTextBox.Text);

    private static void OpenFolder(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    private void SetStatus(string text) => RunStatusText.Text = text;
}
