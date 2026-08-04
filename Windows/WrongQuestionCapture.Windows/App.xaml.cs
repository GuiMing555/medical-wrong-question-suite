using System.Threading;
using System.Windows;

namespace WrongQuestionCapture.Windows;

public partial class App : System.Windows.Application
{
    private const string InstanceMutexName = @"Local\MedicalQuestionSuite.Capture.Instance";
    private const string OrganizeRequestEventName = @"Local\MedicalQuestionSuite.Capture.OrganizeNow";
    private Mutex? _instanceMutex;
    private EventWaitHandle? _organizeRequestEvent;
    private CancellationTokenSource? _listenerCancellation;
    private AppHost? _host;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var organizeOnly = e.Args.Any(value => value.Equals("--organize-now", StringComparison.OrdinalIgnoreCase));
        _instanceMutex = new Mutex(true, InstanceMutexName, out var ownsInstance);
        if (!ownsInstance)
        {
            if (organizeOnly)
            {
                using var signal = new EventWaitHandle(false, EventResetMode.AutoReset, OrganizeRequestEventName);
                signal.Set();
            }
            else
            {
                MessageBox.Show("错题截图整理已在运行。", "医学综合错题截图", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            Shutdown();
            return;
        }

        _host = new AppHost();
        if (organizeOnly)
        {
            try
            {
                await _host.Organizer.OrganizeAsync();
                Shutdown(0);
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "整理失败", MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(1);
            }
            return;
        }

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var window = new MainWindow(_host);
        MainWindow = window;
        window.Show();
        StartOrganizeRequestListener(window);
    }

    private void StartOrganizeRequestListener(MainWindow window)
    {
        _listenerCancellation = new CancellationTokenSource();
        _organizeRequestEvent = new EventWaitHandle(false, EventResetMode.AutoReset, OrganizeRequestEventName);
        var token = _listenerCancellation.Token;
        _ = Task.Run(() =>
        {
            WaitHandle.WaitAny([_organizeRequestEvent, token.WaitHandle]);
            while (!token.IsCancellationRequested)
            {
                Dispatcher.BeginInvoke(new Action(window.RunOrganizerFromExternalRequest));
                WaitHandle.WaitAny([_organizeRequestEvent, token.WaitHandle]);
            }
        }, token);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _listenerCancellation?.Cancel();
        _organizeRequestEvent?.Dispose();
        _host?.Dispose();
        if (_instanceMutex is not null)
        {
            try { _instanceMutex.ReleaseMutex(); } catch (ApplicationException) { }
            _instanceMutex.Dispose();
        }
        base.OnExit(e);
    }
}
