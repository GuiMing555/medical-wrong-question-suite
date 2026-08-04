using MedicalQuestionSuite.Core;

namespace MedicalQuestionPractice.Windows.Services;

public interface IQuestionBankService
{
    Task<DashboardSnapshot> GetDashboardAsync();
    Task<SettingsSnapshot> GetSettingsAsync();
    Task UpdateSettingsAsync(SettingsSnapshot settings);
    Task<PracticeSessionSnapshot?> GetCurrentSessionAsync(PracticeMode? mode = null);
    Task<PracticeSessionSnapshot> StartSessionAsync(PracticeMode mode, bool resumeExisting = true);
    Task<SubmissionResult> SubmitAsync(SubmitAnswerRequest request);
    Task MarkQuestionAsUnsureAsync(string questionId);
    Task<bool> PollForChangesAsync();
}
