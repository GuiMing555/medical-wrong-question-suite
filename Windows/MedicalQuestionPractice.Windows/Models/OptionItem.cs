using MedicalQuestionPractice.Windows.ViewModels;
using MedicalQuestionSuite.Core;

namespace MedicalQuestionPractice.Windows.Models;

public sealed class OptionItem : ObservableObject
{
    private readonly Action<OptionItem> _selectionChanged;
    private bool _isSelected;
    private bool _isSelectionEnabled = true;
    private bool _isCorrectAfterSubmit;
    private bool _isIncorrectSelected;

    public OptionItem(PracticeOption option, int index, Action<OptionItem> selectionChanged)
    {
        Id = option.Id;
        OriginalLabel = option.OriginalLabel;
        Label = index < 26 ? ((char)('A' + index)).ToString() : (index + 1).ToString();
        Text = option.Text;
        _selectionChanged = selectionChanged;
    }

    public string Id { get; }
    public string? OriginalLabel { get; }
    public string Label { get; }
    public string Text { get; }
    public string DisplayText => $"{Label}.  {Text}";

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (SetProperty(ref _isSelected, value) && value)
            {
                _selectionChanged(this);
            }
        }
    }

    public bool IsSelectionEnabled
    {
        get => _isSelectionEnabled;
        set => SetProperty(ref _isSelectionEnabled, value);
    }

    public bool IsCorrectAfterSubmit
    {
        get => _isCorrectAfterSubmit;
        set => SetProperty(ref _isCorrectAfterSubmit, value);
    }

    public bool IsIncorrectSelected
    {
        get => _isIncorrectSelected;
        set => SetProperty(ref _isIncorrectSelected, value);
    }

    public void SetSelectedSilently(bool selected) => SetProperty(ref _isSelected, selected, nameof(IsSelected));
}
