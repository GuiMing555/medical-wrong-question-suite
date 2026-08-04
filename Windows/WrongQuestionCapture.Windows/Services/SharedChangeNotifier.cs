namespace WrongQuestionCapture.Windows;

internal sealed class SharedChangeNotifier : IDisposable
{
    public const string EventName = @"Local\MedicalQuestionSuite.DatabaseChanged";
    private readonly EventWaitHandle _event = new(false, EventResetMode.AutoReset, EventName);

    public void Notify() => _event.Set();
    public void Dispose() => _event.Dispose();
}
