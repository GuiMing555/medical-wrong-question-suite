using MedicalQuestionSuite.Core;

namespace WrongQuestionCapture.Windows;

internal sealed class AppHost : IDisposable
{
    public SettingsStore SettingsStore { get; } = new();
    public WindowTargetService WindowTarget { get; } = new();
    public WindowCaptureService WindowCapture { get; } = new();
    public WindowsOcrService Ocr { get; } = new();
    public CaptureOrganizer Organizer { get; }
    public TaskSchedulerService Scheduler { get; } = new();
    public SharedChangeNotifier ChangeNotifier { get; } = new();

    public AppHost()
    {
        var store = new QuestionBankStore(sourceApplication: "capture-windows");
        Organizer = new CaptureOrganizer(SettingsStore, Ocr, store, ChangeNotifier);
    }

    public void Dispose()
    {
        Organizer.Dispose();
        ChangeNotifier.Dispose();
    }
}
