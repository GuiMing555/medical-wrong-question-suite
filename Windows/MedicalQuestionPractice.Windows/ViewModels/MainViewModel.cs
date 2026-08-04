using System.Windows;
using System.Windows.Threading;
using MedicalQuestionPractice.Windows.Services;
using MedicalQuestionSuite.Core;

namespace MedicalQuestionPractice.Windows.ViewModels;

public sealed class MainViewModel : ObservableObject
{
    private readonly IQuestionBankService _service;
    private readonly DispatcherTimer _changeTimer;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private object? _currentPage;
    private bool _isBusy;
    private HomeViewModel? _home;

    public MainViewModel(IQuestionBankService service)
    {
        _service = service;
        GoHomeCommand = new AsyncRelayCommand(ShowHomeAsync);
        StartNormalCommand = new AsyncRelayCommand(() => OpenPracticeAsync(PracticeMode.Normal));
        StartWrongBookCommand = new AsyncRelayCommand(
            () => OpenPracticeAsync(PracticeMode.WrongBook),
            () => _home?.WrongBookCount > 0);
        OpenSettingsCommand = new AsyncRelayCommand(OpenSettingsAsync);

        _changeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _changeTimer.Tick += async (_, _) => await PollChangesAsync();
    }

    public object? CurrentPage
    {
        get => _currentPage;
        private set => SetProperty(ref _currentPage, value);
    }

    public bool IsBusy
    {
        get => _isBusy;
        private set => SetProperty(ref _isBusy, value);
    }

    public AsyncRelayCommand GoHomeCommand { get; }
    public AsyncRelayCommand StartNormalCommand { get; }
    public AsyncRelayCommand StartWrongBookCommand { get; }
    public AsyncRelayCommand OpenSettingsCommand { get; }

    public async Task InitializeAsync()
    {
        await ShowHomeAsync();
        await _service.PollForChangesAsync();
        _changeTimer.Start();
    }

    public async Task RefreshForActivationAsync()
    {
        if (!await _refreshLock.WaitAsync(0))
        {
            return;
        }

        try
        {
            await RefreshVisiblePageAsync();
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private async Task ShowHomeAsync()
    {
        await RunBusyAsync(async () =>
        {
            _home ??= new HomeViewModel(
                _service,
                () => OpenPracticeAsync(PracticeMode.Normal),
                () => OpenPracticeAsync(PracticeMode.WrongBook),
                OpenSettingsAsync);
            await _home.RefreshAsync();
            CurrentPage = _home;
            StartWrongBookCommand.NotifyCanExecuteChanged();
        });
    }

    private async Task OpenPracticeAsync(PracticeMode mode)
    {
        await RunBusyAsync(async () =>
        {
            var practice = new PracticeViewModel(_service, mode, ShowHomeAsync);
            await practice.InitializeAsync();
            CurrentPage = practice;
        });
    }

    private async Task OpenSettingsAsync()
    {
        await RunBusyAsync(async () =>
        {
            var settings = new SettingsViewModel(_service, ShowHomeAsync);
            await settings.InitializeAsync();
            CurrentPage = settings;
        });
    }

    private async Task PollChangesAsync()
    {
        try
        {
            if (await _service.PollForChangesAsync())
            {
                await RefreshVisiblePageAsync();
            }
        }
        catch
        {
            // 共享数据库可能正被截图程序短暂写入；下一轮轮询会再次刷新。
        }
    }

    private async Task RefreshVisiblePageAsync()
    {
        switch (CurrentPage)
        {
            case HomeViewModel home:
                await home.RefreshAsync();
                StartWrongBookCommand.NotifyCanExecuteChanged();
                break;
            case PracticeViewModel practice when !practice.HasSubmittedAnswer:
                await practice.RefreshCurrentSessionAsync();
                break;
        }
    }

    private async Task RunBusyAsync(Func<Task> action)
    {
        IsBusy = true;
        try
        {
            await action();
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "操作未完成", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            IsBusy = false;
        }
    }
}
