using MedicalQuestionSuite.Core;

namespace MedicalQuestionPractice.Windows.Services;

public sealed class QuestionBankService : IQuestionBankService
{
    private readonly QuestionBankStore _store;
    private long _lastChangeSequence;

    public QuestionBankService()
    {
        _store = new QuestionBankStore(sourceApplication: "medical-question-practice-windows");
    }

    public Task<DashboardSnapshot> GetDashboardAsync() => Task.Run(() => _store.Dashboard());

    public Task<SettingsSnapshot> GetSettingsAsync() => Task.Run(() => _store.Settings());

    public Task UpdateSettingsAsync(SettingsSnapshot settings) => Task.Run(() => _store.UpdateSettings(settings));

    public Task<PracticeSessionSnapshot?> GetCurrentSessionAsync(PracticeMode? mode = null) =>
        Task.Run(() => _store.CurrentSession(mode));

    public Task<PracticeSessionSnapshot> StartSessionAsync(PracticeMode mode, bool resumeExisting = true) =>
        Task.Run(() => _store.StartSession(mode, resumeExisting: resumeExisting));

    public Task<SubmissionResult> SubmitAsync(SubmitAnswerRequest request) =>
        Task.Run(() => _store.Submit(request));

    public Task MarkQuestionAsUnsureAsync(string questionId) =>
        Task.Run(() => _store.MarkQuestionAsUnsure(questionId));

    public async Task<bool> PollForChangesAsync()
    {
        var changes = await Task.Run(() => _store.Changes(_lastChangeSequence, 500));
        if (changes.Count == 0)
        {
            return false;
        }

        _lastChangeSequence = changes.Max(change => change.Sequence);
        return true;
    }
}
