using System.Text.Json;
using System.Text.Json.Serialization;

namespace MedicalQuestionSuite.Core;

[JsonConverter(typeof(PracticeModeJsonConverter))]
public enum PracticeMode
{
    Normal,
    WrongBook
}

[JsonConverter(typeof(QuestionTypeJsonConverter))]
public enum QuestionType
{
    SingleChoice,
    MultipleChoice
}

public sealed record OptionDraft(
    string? Id,
    string? OriginalLabel,
    string Text,
    bool IsCorrect)
{
    public OptionDraft(string? originalLabel, string text, bool isCorrect)
        : this(null, originalLabel, text, isCorrect) { }
}

public sealed record QuestionDraft(
    string StableExternalID,
    string Stem,
    QuestionType Type,
    IReadOnlyList<OptionDraft> Options,
    string Explanation = "",
    IReadOnlyList<string>? KnowledgePoints = null,
    string? Source = null,
    string? SourceImagePath = null,
    string? SourceImageHash = null,
    DateTimeOffset? CapturedAt = null,
    string? Id = null);

public sealed record CapturedQuestionOption(string OriginalLabel, string Text);

public sealed record CapturedQuestionDraft(
    string StableExternalID,
    string Stem,
    IReadOnlyList<CapturedQuestionOption> Options,
    IReadOnlySet<string> CorrectLabels,
    string Explanation,
    IReadOnlyList<string> KnowledgePoints,
    string SourceImagePath,
    string SourceImageHash,
    DateTimeOffset CapturedAt,
    string Source = "capture")
{
    public static IReadOnlySet<string> LabelsFromAnswer(string answer) =>
        answer.ToUpperInvariant()
            .Where(character => character is >= 'A' and <= 'Z')
            .Select(character => character.ToString())
            .ToHashSet(StringComparer.Ordinal);
}

[JsonConverter(typeof(QuestionImportStatusJsonConverter))]
public enum QuestionImportStatus
{
    Inserted,
    Updated,
    Unchanged
}

public sealed record QuestionImportResult(
    string QuestionID,
    QuestionImportStatus Status,
    bool AddedToWrongBook);

public sealed record SettingsSnapshot(
    int NormalReviewIntervalDays = 7,
    int WrongRequiredConsecutiveCorrect = 3,
    int? QuestionsPerSession = null);

public sealed record PracticeOption(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("originalLabel")] string? OriginalLabel);

public sealed record PracticeQuestion(
    [property: JsonPropertyName("itemID")] string ItemID,
    [property: JsonPropertyName("questionID")] string QuestionID,
    [property: JsonPropertyName("stem")] string Stem,
    [property: JsonPropertyName("type")] QuestionType Type,
    [property: JsonPropertyName("options")] IReadOnlyList<PracticeOption> Options,
    [property: JsonPropertyName("explanation")] string Explanation,
    [property: JsonPropertyName("wrongProgress")] int WrongProgress,
    [property: JsonPropertyName("wrongRequired")] int WrongRequired)
{
    [JsonIgnore]
    public bool AllowsMultipleSelection => Type == QuestionType.MultipleChoice;
}

public sealed record PracticeSessionSummary(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("mode")] PracticeMode Mode,
    [property: JsonPropertyName("currentIndex")] int CurrentIndex,
    [property: JsonPropertyName("totalCount")] int TotalCount,
    [property: JsonPropertyName("answeredCount")] int AnsweredCount,
    [property: JsonPropertyName("isComplete")] bool IsComplete);

public sealed record PracticeSessionSnapshot(
    [property: JsonPropertyName("summary")] PracticeSessionSummary Summary,
    [property: JsonPropertyName("currentItem")] PracticeQuestion? CurrentItem)
{
    [JsonIgnore] public string Id => Summary.Id;
    [JsonIgnore] public PracticeMode Mode => Summary.Mode;
    [JsonIgnore] public int CurrentIndex => Summary.CurrentIndex;
    [JsonIgnore] public int TotalCount => Summary.TotalCount;
    [JsonIgnore] public int AnsweredCount => Summary.AnsweredCount;
    [JsonIgnore] public bool IsComplete => Summary.IsComplete;
}

public sealed record DashboardSnapshot(
    int TotalQuestions,
    int UnseenCount,
    int DueNormalCount,
    int WrongBookCount,
    int AnsweredTodayCount,
    PracticeSessionSummary? ActiveSession);

public sealed record ChangeLogEntry(
    long Sequence,
    string SourceApplication,
    string EntityType,
    string EntityID,
    string Action,
    string? PayloadJSON,
    DateTimeOffset CreatedAt);

public sealed record SubmitAnswerRequest(
    string SessionID,
    string ItemID,
    IReadOnlySet<string> SelectedOptionIDs,
    string? SubmissionToken = null,
    bool MarkAsUnsure = false,
    DateTimeOffset? SubmittedAt = null)
{
    public string EffectiveSubmissionToken { get; } = SubmissionToken ?? Guid.NewGuid().ToString();
    public DateTimeOffset EffectiveSubmittedAt { get; } = SubmittedAt ?? DateTimeOffset.Now;
}

public sealed record SubmissionResult(
    [property: JsonPropertyName("attemptID")] string AttemptID,
    [property: JsonPropertyName("isCorrect")] bool IsCorrect,
    [property: JsonPropertyName("correctOptionIDs"), JsonConverter(typeof(ReadOnlyStringSetJsonConverter))] IReadOnlySet<string> CorrectOptionIDs,
    [property: JsonPropertyName("selectedOptionIDs"), JsonConverter(typeof(ReadOnlyStringSetJsonConverter))] IReadOnlySet<string> SelectedOptionIDs,
    [property: JsonPropertyName("explanation")] string Explanation,
    [property: JsonPropertyName("markedAsUnsure")] bool MarkedAsUnsure,
    [property: JsonPropertyName("isInWrongBook")] bool IsInWrongBook,
    [property: JsonPropertyName("wrongProgressBefore")] int WrongProgressBefore,
    [property: JsonPropertyName("wrongProgressAfter")] int WrongProgressAfter,
    [property: JsonPropertyName("removedFromWrongBook")] bool RemovedFromWrongBook,
    [property: JsonPropertyName("session")] PracticeSessionSnapshot Session);

public enum QuestionBankErrorCode
{
    InvalidQuestion,
    InvalidSettings,
    NoEligibleQuestions,
    SessionNotFound,
    SessionCompleted,
    SessionItemNotFound,
    ItemAlreadyAnswered,
    ItemIsNotCurrent,
    InvalidSelection,
    Database
}

public sealed class QuestionBankException : Exception
{
    public QuestionBankException(QuestionBankErrorCode code, string message, PracticeMode? mode = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
        Mode = mode;
    }

    public QuestionBankErrorCode Code { get; }
    public PracticeMode? Mode { get; }
}

public static class DatabasePaths
{
    public static string DefaultDatabasePath
    {
        get
        {
            var basePath = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(basePath))
            {
                throw new InvalidOperationException("无法确定本地应用数据目录");
            }

            return Path.Combine(basePath, "医学综合练习", "question-bank.sqlite3");
        }
    }
}

internal static class JsonSupport
{
    internal static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = null,
        PropertyNameCaseInsensitive = false,
        WriteIndented = false
    };

    internal static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);

    internal static T Deserialize<T>(string value) =>
        JsonSerializer.Deserialize<T>(value, Options)
        ?? throw new QuestionBankException(QuestionBankErrorCode.Database, "JSON 记录为空");
}

public sealed class PracticeModeJsonConverter : JsonConverter<PracticeMode>
{
    public override PracticeMode Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "normal" => PracticeMode.Normal,
            "wrong_book" => PracticeMode.WrongBook,
            _ => throw new JsonException("未知练习模式")
        };

    public override void Write(Utf8JsonWriter writer, PracticeMode value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value == PracticeMode.Normal ? "normal" : "wrong_book");
}

public sealed class QuestionTypeJsonConverter : JsonConverter<QuestionType>
{
    public override QuestionType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "single_choice" => QuestionType.SingleChoice,
            "multiple_choice" => QuestionType.MultipleChoice,
            _ => throw new JsonException("未知题型")
        };

    public override void Write(Utf8JsonWriter writer, QuestionType value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value == QuestionType.SingleChoice ? "single_choice" : "multiple_choice");
}

public sealed class QuestionImportStatusJsonConverter : JsonConverter<QuestionImportStatus>
{
    public override QuestionImportStatus Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "inserted" => QuestionImportStatus.Inserted,
            "updated" => QuestionImportStatus.Updated,
            "unchanged" => QuestionImportStatus.Unchanged,
            _ => throw new JsonException("未知导入状态")
        };

    public override void Write(Utf8JsonWriter writer, QuestionImportStatus value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            QuestionImportStatus.Inserted => "inserted",
            QuestionImportStatus.Updated => "updated",
            _ => "unchanged"
        });
}

public sealed class ReadOnlyStringSetJsonConverter : JsonConverter<IReadOnlySet<string>>
{
    public override IReadOnlySet<string> Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        JsonSerializer.Deserialize<string[]>(ref reader, options)?.ToHashSet(StringComparer.Ordinal)
        ?? new HashSet<string>(StringComparer.Ordinal);

    public override void Write(Utf8JsonWriter writer, IReadOnlySet<string> value, JsonSerializerOptions options) =>
        JsonSerializer.Serialize(writer, value.OrderBy(item => item, StringComparer.Ordinal).ToArray(), options);
}
