namespace WrongQuestionCapture.Windows;

internal sealed record ParsedOption(string Label, string Text);

internal sealed record ParsedCapturedQuestion(
    string Stem,
    IReadOnlyList<ParsedOption> Options,
    IReadOnlySet<string> CorrectLabels,
    string Explanation,
    IReadOnlyList<string> KnowledgePoints,
    IReadOnlyList<string> Issues)
{
    public bool NeedsReview => Issues.Count > 0;
}

internal sealed class CapturedRecord
{
    public string Id { get; set; } = string.Empty;
    public string SourcePath { get; set; } = string.Empty;
    public string SourceHash { get; set; } = string.Empty;
    public DateTimeOffset CapturedAt { get; set; }
    public DateTimeOffset RecognizedAt { get; set; }
    public string RawText { get; set; } = string.Empty;
    public string Stem { get; set; } = string.Empty;
    public List<ParsedOption> Options { get; set; } = [];
    public HashSet<string> CorrectLabels { get; set; } = new(StringComparer.Ordinal);
    public string Explanation { get; set; } = string.Empty;
    public List<string> KnowledgePoints { get; set; } = [];
    public List<string> Issues { get; set; } = [];
    public bool NeedsReview => Issues.Count > 0;
}

internal sealed class CaptureState
{
    public int SchemaVersion { get; set; } = 1;
    public DateTimeOffset? LastRunAt { get; set; }
    public List<CapturedRecord> Items { get; set; } = [];
}
