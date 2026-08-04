using MedicalQuestionPractice.Windows.Services;
using MedicalQuestionSuite.Core;

namespace MedicalQuestionPractice.Windows.ViewModels;

public sealed class HomeViewModel : ObservableObject
{
    private readonly IQuestionBankService _service;
    private int _totalQuestions;
    private int _unseenCount;
    private int _dueNormalCount;
    private int _wrongBookCount;
    private int _answeredTodayCount;
    private string _activeSessionText = "没有未完成练习";
    private bool _hasActiveSession;
    private bool _hasActiveNormalSession;

    public HomeViewModel(
        IQuestionBankService service,
        Func<Task> startNormal,
        Func<Task> startWrongBook,
        Func<Task> openSettings)
    {
        _service = service;
        StartNormalCommand = new AsyncRelayCommand(startNormal, () => NormalAvailable);
        StartWrongBookCommand = new AsyncRelayCommand(startWrongBook, () => WrongBookCount > 0);
        OpenSettingsCommand = new AsyncRelayCommand(openSettings);
    }

    public int TotalQuestions { get => _totalQuestions; private set => SetProperty(ref _totalQuestions, value); }
    public int UnseenCount { get => _unseenCount; private set => SetProperty(ref _unseenCount, value); }
    public int DueNormalCount { get => _dueNormalCount; private set => SetProperty(ref _dueNormalCount, value); }
    public int WrongBookCount
    {
        get => _wrongBookCount;
        private set
        {
            if (SetProperty(ref _wrongBookCount, value))
            {
                OnPropertyChanged(nameof(WrongBookButtonText));
                StartWrongBookCommand.NotifyCanExecuteChanged();
            }
        }
    }
    public int AnsweredTodayCount { get => _answeredTodayCount; private set => SetProperty(ref _answeredTodayCount, value); }
    public string ActiveSessionText { get => _activeSessionText; private set => SetProperty(ref _activeSessionText, value); }
    public bool HasActiveSession { get => _hasActiveSession; private set => SetProperty(ref _hasActiveSession, value); }
    public bool NormalAvailable => UnseenCount + DueNormalCount > 0 || _hasActiveNormalSession;
    public string WrongBookButtonText => WrongBookCount > 0 ? $"错题模式（{WrongBookCount} 题）" : "错题模式（暂无错题）";

    public AsyncRelayCommand StartNormalCommand { get; }
    public AsyncRelayCommand StartWrongBookCommand { get; }
    public AsyncRelayCommand OpenSettingsCommand { get; }

    public async Task RefreshAsync()
    {
        var dashboardTask = _service.GetDashboardAsync();
        var normalSessionTask = _service.GetCurrentSessionAsync(PracticeMode.Normal);
        var wrongSessionTask = _service.GetCurrentSessionAsync(PracticeMode.WrongBook);
        await Task.WhenAll(dashboardTask, normalSessionTask, wrongSessionTask);
        var dashboard = await dashboardTask;
        var normalSession = await normalSessionTask;
        var wrongSession = await wrongSessionTask;
        TotalQuestions = dashboard.TotalQuestions;
        UnseenCount = dashboard.UnseenCount;
        DueNormalCount = dashboard.DueNormalCount;
        WrongBookCount = dashboard.WrongBookCount;
        AnsweredTodayCount = dashboard.AnsweredTodayCount;
        _hasActiveNormalSession = normalSession is not null;
        HasActiveSession = normalSession is not null || wrongSession is not null;
        ActiveSessionText = FormatActiveSessions(normalSession?.Summary, wrongSession?.Summary);
        OnPropertyChanged(nameof(NormalAvailable));
        StartNormalCommand.NotifyCanExecuteChanged();
    }

    private static string FormatActiveSessions(PracticeSessionSummary? normal, PracticeSessionSummary? wrong)
    {
        if (normal is null && wrong is null)
        {
            return "没有未完成练习";
        }

        var sessions = new[] { normal, wrong }.Where(session => session is not null).Select(session =>
        {
            var mode = session!.Mode == PracticeMode.WrongBook ? "错题模式" : "普通模式";
            return $"{mode} {session.AnsweredCount}/{session.TotalCount} 题";
        });
        return "可继续：" + string.Join("；", sessions);
    }
}
