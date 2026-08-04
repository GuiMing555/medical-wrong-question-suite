using System.Windows;
using MedicalQuestionPractice.Windows.ViewModels;

namespace MedicalQuestionPractice.Windows;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }

    private void Window_Activated(object? sender, EventArgs e)
    {
        if (DataContext is MainViewModel viewModel)
        {
            _ = viewModel.RefreshForActivationAsync();
        }
    }
}
