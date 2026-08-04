using System.Collections.ObjectModel;
using MedicalQuestionPractice.Windows.Models;
using MedicalQuestionPractice.Windows.Services;
using MedicalQuestionSuite.Core;

namespace MedicalQuestionPractice.Windows.ViewModels;

public sealed class PracticeViewModel : ObservableObject
{
    private readonly IQuestionBankService _service;
    private readonly PracticeMode _mode;
    private readonly Func<Task> _goHome;
    private PracticeSessionSnapshot? _session;
    private PracticeQuestion? _question;
    private string _stem = "";
    private string _progressText = "";
    private string _questionTypeText = "";
    private string _wrongProgressText = "";
    private bool _isUnsure;
    private bool _hasSubmittedAnswer;
    private bool _isCorrect;
    private string _feedbackTitle = "";
    private string _feedbackDetail = "";
    private string _correctAnswerText = "";
    private string _explanation = "";
    private string _explanationOptionMapping = "";
    private string _nextButtonText = "下一题  Enter";
    private bool _isSubmitting;
    private string _submissionToken = Guid.NewGuid().ToString();

    public PracticeViewModel(IQuestionBankService service, PracticeMode mode, Func<Task> goHome)
    {
        _service = service;
        _mode = mode;
        _goHome = goHome;
        SubmitCommand = new AsyncRelayCommand(SubmitAsync, CanSubmit);
        NextCommand = new AsyncRelayCommand(NextAsync, () => HasSubmittedAnswer);
        SubmitOrNextCommand = new AsyncRelayCommand(SubmitOrNextAsync, () => !_isSubmitting);
        SelectOptionByIndexCommand = new RelayCommand(SelectOptionByIndex);
        ToggleUnsureCommand = new RelayCommand(() => IsUnsure = !IsUnsure, () => !HasSubmittedAnswer);
    }

    public ObservableCollection<OptionItem> Options { get; } = [];
    public string ModeTitle => _mode == PracticeMode.WrongBook ? "错题模式" : "普通模式";
    public string Stem { get => _stem; private set => SetProperty(ref _stem, value); }
    public string ProgressText { get => _progressText; private set => SetProperty(ref _progressText, value); }
    public string QuestionTypeText { get => _questionTypeText; private set => SetProperty(ref _questionTypeText, value); }
    public string WrongProgressText { get => _wrongProgressText; private set => SetProperty(ref _wrongProgressText, value); }
    public bool IsUnsure { get => _isUnsure; set => SetProperty(ref _isUnsure, value); }
    public bool HasSubmittedAnswer
    {
        get => _hasSubmittedAnswer;
        private set
        {
            if (SetProperty(ref _hasSubmittedAnswer, value))
            {
                SubmitCommand.NotifyCanExecuteChanged();
                NextCommand.NotifyCanExecuteChanged();
                ToggleUnsureCommand.NotifyCanExecuteChanged();
            }
        }
    }
    public bool IsCorrect { get => _isCorrect; private set => SetProperty(ref _isCorrect, value); }
    public string FeedbackTitle { get => _feedbackTitle; private set => SetProperty(ref _feedbackTitle, value); }
    public string FeedbackDetail { get => _feedbackDetail; private set => SetProperty(ref _feedbackDetail, value); }
    public string CorrectAnswerText { get => _correctAnswerText; private set => SetProperty(ref _correctAnswerText, value); }
    public string Explanation { get => _explanation; private set => SetProperty(ref _explanation, value); }
    public string ExplanationOptionMapping { get => _explanationOptionMapping; private set => SetProperty(ref _explanationOptionMapping, value); }
    public string NextButtonText { get => _nextButtonText; private set => SetProperty(ref _nextButtonText, value); }

    public AsyncRelayCommand SubmitCommand { get; }
    public AsyncRelayCommand NextCommand { get; }
    public AsyncRelayCommand SubmitOrNextCommand { get; }
    public RelayCommand SelectOptionByIndexCommand { get; }
    public RelayCommand ToggleUnsureCommand { get; }

    public async Task InitializeAsync()
    {
        var current = await _service.GetCurrentSessionAsync(_mode);
        _session = current ?? await _service.StartSessionAsync(_mode, resumeExisting: true);
        ShowSession(_session);
    }

    public async Task RefreshCurrentSessionAsync()
    {
        var fresh = await _service.GetCurrentSessionAsync(_mode);
        if (fresh?.CurrentItem is null || fresh.CurrentItem.ItemID == _question?.ItemID)
        {
            return;
        }

        _session = fresh;
        ShowSession(fresh);
    }

    private void ShowSession(PracticeSessionSnapshot session)
    {
        _session = session;
        _question = session.CurrentItem;
        _submissionToken = Guid.NewGuid().ToString();
        HasSubmittedAnswer = false;
        IsUnsure = false;
        FeedbackTitle = "";
        FeedbackDetail = "";
        CorrectAnswerText = "";
        Explanation = "";
        ExplanationOptionMapping = "";
        Options.Clear();

        if (_question is null)
        {
            ProgressText = $"已完成 {session.AnsweredCount}/{session.TotalCount} 题";
            NextButtonText = "返回主页  Enter";
            HasSubmittedAnswer = true;
            return;
        }

        Stem = _question.Stem;
        ProgressText = $"第 {session.CurrentIndex + 1} / {session.TotalCount} 题";
        QuestionTypeText = _question.AllowsMultipleSelection ? "多选题" : "单选题";
        WrongProgressText = _mode == PracticeMode.WrongBook
            ? $"连续答对 {_question.WrongProgress}/{_question.WrongRequired} 次后移出错题本"
            : "";
        for (var index = 0; index < _question.Options.Count; index++)
        {
            Options.Add(new OptionItem(_question.Options[index], index, OnOptionSelected));
        }

        NextButtonText = "下一题  Enter";
        SubmitCommand.NotifyCanExecuteChanged();
    }

    private void OnOptionSelected(OptionItem selected)
    {
        if (_question?.AllowsMultipleSelection == false)
        {
            foreach (var option in Options.Where(option => option != selected))
            {
                option.SetSelectedSilently(false);
            }
        }
        SubmitCommand.NotifyCanExecuteChanged();
    }

    private bool CanSubmit() =>
        !_isSubmitting && !HasSubmittedAnswer && _question is not null && Options.Any(option => option.IsSelected);

    private async Task SubmitAsync()
    {
        if (_session is null || _question is null || !CanSubmit())
        {
            return;
        }

        _isSubmitting = true;
        SubmitCommand.NotifyCanExecuteChanged();
        SubmitOrNextCommand.NotifyCanExecuteChanged();
        try
        {
            var selectedIds = Options.Where(option => option.IsSelected).Select(option => option.Id).ToHashSet(StringComparer.Ordinal);
            var request = new SubmitAnswerRequest(
                _session.Id,
                _question.ItemID,
                selectedIds,
                SubmissionToken: _submissionToken,
                MarkAsUnsure: IsUnsure,
                SubmittedAt: DateTimeOffset.Now);
            var result = await _service.SubmitAsync(request);
            _session = result.Session;

            IsCorrect = result.IsCorrect;
            HasSubmittedAnswer = true;
            foreach (var option in Options)
            {
                option.IsSelectionEnabled = false;
                option.IsCorrectAfterSubmit = result.CorrectOptionIDs.Contains(option.Id);
                option.IsIncorrectSelected = option.IsSelected && !result.CorrectOptionIDs.Contains(option.Id);
            }

            FeedbackTitle = result.IsCorrect
                ? (result.MarkedAsUnsure ? "答案正确，已按仍需练习记录" : "回答正确")
                : "回答错误，已加入错题本";
            FeedbackDetail = FormatWrongBookFeedback(result);
            CorrectAnswerText = "正确答案：" + string.Join("、", Options.Where(option => result.CorrectOptionIDs.Contains(option.Id)).Select(option => option.Label));
            Explanation = string.IsNullOrWhiteSpace(result.Explanation) ? "本题暂无解析。" : result.Explanation;
            ExplanationOptionMapping = BuildOptionMapping();
            NextButtonText = result.Session.IsComplete ? "完成并返回主页  Enter" : "下一题  Enter";
        }
        finally
        {
            _isSubmitting = false;
            SubmitCommand.NotifyCanExecuteChanged();
            SubmitOrNextCommand.NotifyCanExecuteChanged();
        }
    }

    private static string FormatWrongBookFeedback(SubmissionResult result)
    {
        if (result.RemovedFromWrongBook)
        {
            return $"已连续答对 {result.WrongProgressAfter} 次，已自动移出错题本。";
        }

        if (result.IsInWrongBook)
        {
            return result.WrongProgressAfter > 0
                ? $"仍在错题本，当前连续答对 {result.WrongProgressAfter} 次。"
                : "仍在错题本；再次答错或标记为仍需练习会从 0 重新累计。";
        }

        return "本题状态已保存。";
    }

    private string BuildOptionMapping()
    {
        var mappings = Options
            .Where(option => !string.IsNullOrWhiteSpace(option.OriginalLabel))
            .Select(option => $"原{option.OriginalLabel!.Trim()}→现{option.Label}")
            .ToArray();
        if (mappings.Length == 0 || Options.All(option =>
                string.IsNullOrWhiteSpace(option.OriginalLabel) ||
                string.Equals(option.OriginalLabel.Trim(), option.Label, StringComparison.OrdinalIgnoreCase)))
        {
            return "";
        }

        return "解析中的选项字母沿用题库原始标号。本次选项映射：" + string.Join("，", mappings);
    }

    private async Task NextAsync()
    {
        if (!HasSubmittedAnswer || _session is null)
        {
            return;
        }

        if (_session.IsComplete || _session.CurrentItem is null)
        {
            await _goHome();
            return;
        }

        ShowSession(_session);
    }

    private Task SubmitOrNextAsync() => HasSubmittedAnswer ? NextAsync() : SubmitAsync();

    private void SelectOptionByIndex(object? parameter)
    {
        if (HasSubmittedAnswer || !int.TryParse(parameter?.ToString(), out var index) || index < 0 || index >= Options.Count)
        {
            return;
        }

        var option = Options[index];
        option.IsSelected = _question?.AllowsMultipleSelection == true ? !option.IsSelected : true;
        SubmitCommand.NotifyCanExecuteChanged();
    }
}
