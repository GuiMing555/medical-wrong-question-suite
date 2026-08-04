using MedicalQuestionPractice.Windows.Services;
using MedicalQuestionSuite.Core;

namespace MedicalQuestionPractice.Windows.ViewModels;

public sealed class SettingsViewModel : ObservableObject
{
    private readonly IQuestionBankService _service;
    private readonly Func<Task> _goHome;
    private string _reviewIntervalDays = "7";
    private string _requiredConsecutiveCorrect = "3";
    private string _questionsPerSession = "";
    private string _validationMessage = "";
    private string _savedMessage = "";

    public SettingsViewModel(IQuestionBankService service, Func<Task> goHome)
    {
        _service = service;
        _goHome = goHome;
        SaveCommand = new AsyncRelayCommand(SaveAsync);
        CancelCommand = new AsyncRelayCommand(goHome);
    }

    public string ReviewIntervalDays { get => _reviewIntervalDays; set { SetProperty(ref _reviewIntervalDays, value); ClearMessages(); } }
    public string RequiredConsecutiveCorrect { get => _requiredConsecutiveCorrect; set { SetProperty(ref _requiredConsecutiveCorrect, value); ClearMessages(); } }
    public string QuestionsPerSession { get => _questionsPerSession; set { SetProperty(ref _questionsPerSession, value); ClearMessages(); } }
    public string ValidationMessage { get => _validationMessage; private set => SetProperty(ref _validationMessage, value); }
    public string SavedMessage { get => _savedMessage; private set => SetProperty(ref _savedMessage, value); }

    public AsyncRelayCommand SaveCommand { get; }
    public AsyncRelayCommand CancelCommand { get; }

    public async Task InitializeAsync()
    {
        var settings = await _service.GetSettingsAsync();
        ReviewIntervalDays = settings.NormalReviewIntervalDays.ToString();
        RequiredConsecutiveCorrect = settings.WrongRequiredConsecutiveCorrect.ToString();
        QuestionsPerSession = settings.QuestionsPerSession?.ToString() ?? "";
        ClearMessages();
    }

    private async Task SaveAsync()
    {
        if (!int.TryParse(ReviewIntervalDays, out var days) || days < 0)
        {
            ValidationMessage = "普通题复习间隔必须是大于或等于 0 的整数。";
            return;
        }

        if (!int.TryParse(RequiredConsecutiveCorrect, out var required) || required < 1)
        {
            ValidationMessage = "错题移出次数必须是大于 0 的整数。";
            return;
        }

        int? perSession = null;
        if (!string.IsNullOrWhiteSpace(QuestionsPerSession))
        {
            if (!int.TryParse(QuestionsPerSession, out var count) || count < 1)
            {
                ValidationMessage = "每轮题数必须是大于 0 的整数；留空表示不限制。";
                return;
            }
            perSession = count;
        }

        await _service.UpdateSettingsAsync(new SettingsSnapshot(days, required, perSession));
        ValidationMessage = "";
        SavedMessage = "设置已保存，将在新建练习轮次时生效。";
    }

    private void ClearMessages()
    {
        ValidationMessage = "";
        SavedMessage = "";
    }
}
