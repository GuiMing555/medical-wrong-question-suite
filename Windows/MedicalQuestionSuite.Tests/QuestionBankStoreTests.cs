using MedicalQuestionSuite.Core;
using Microsoft.Data.Sqlite;
using Xunit;

namespace MedicalQuestionSuite.Tests;

public sealed class QuestionBankStoreTests : IDisposable
{
    private readonly string _directory;
    private readonly string _databasePath;
    private QuestionBankStore? _store;

    public QuestionBankStoreTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), $"MedicalQuestionSuite.Tests-{Guid.NewGuid()}");
        _databasePath = Path.Combine(_directory, "question-bank.sqlite3");
        _store = new QuestionBankStore(_databasePath, "tests");
    }

    [Fact]
    public void NormalModeUsesUnseenThenOnlyExpiredQuestions()
    {
        InsertQuestion(1);
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var dashboard = Store.Dashboard(now);
        Assert.Equal(1, dashboard.UnseenCount);
        Assert.Equal(0, dashboard.DueNormalCount);

        var session = Store.StartSession(PracticeMode.Normal, now: now, seed: 1);
        Answer(session, true, at: now);
        dashboard = Store.Dashboard(now.AddDays(1));
        Assert.Equal(0, dashboard.UnseenCount);
        Assert.Equal(0, dashboard.DueNormalCount);
        var unavailable = Assert.Throws<QuestionBankException>(() =>
            Store.StartSession(PracticeMode.Normal, now: now.AddDays(1)));
        Assert.Equal(QuestionBankErrorCode.NoEligibleQuestions, unavailable.Code);

        dashboard = Store.Dashboard(now.AddDays(8));
        Assert.Equal(1, dashboard.DueNormalCount);
        Assert.NotNull(Store.StartSession(PracticeMode.Normal, now: now.AddDays(8), seed: 2));
    }

    [Fact]
    public void SessionQuestionAndOptionOrderSurviveProcessRestart()
    {
        InsertQuestion(1);
        InsertQuestion(2);
        var original = Store.StartSession(PracticeMode.Normal, seed: 99);
        var first = Assert.IsType<PracticeQuestion>(original.CurrentItem);
        var firstOrder = first.Options.Select(option => option.Id).ToArray();

        RestartStore();
        var resumed = Assert.IsType<PracticeSessionSnapshot>(Store.CurrentSession(PracticeMode.Normal));
        Assert.Equal(original.Id, resumed.Id);
        Assert.Equal(first.ItemID, resumed.CurrentItem?.ItemID);
        Assert.Equal(firstOrder, resumed.CurrentItem?.Options.Select(option => option.Id));

        Answer(resumed, true);
        RestartStore();
        var progressed = Assert.IsType<PracticeSessionSnapshot>(Store.CurrentSession(PracticeMode.Normal));
        Assert.Equal(1, progressed.CurrentIndex);
        Assert.NotEqual(first.ItemID, progressed.CurrentItem?.ItemID);
    }

    [Fact]
    public void WrongModeIsUnavailableWhenEmptyAndThresholdRemovesQuestion()
    {
        InsertQuestion(1);
        var unavailable = Assert.Throws<QuestionBankException>(() => Store.StartSession(PracticeMode.WrongBook));
        Assert.Equal(QuestionBankErrorCode.NoEligibleQuestions, unavailable.Code);
        Assert.Equal(PracticeMode.WrongBook, unavailable.Mode);

        var normal = Store.StartSession(PracticeMode.Normal, seed: 3);
        Assert.True(Answer(normal, false).IsInWrongBook);
        Store.UpdateSettings(new SettingsSnapshot(7, 2));

        var first = Store.StartSession(PracticeMode.WrongBook, seed: 4);
        var firstCorrect = Answer(first, true);
        Assert.Equal(1, firstCorrect.WrongProgressAfter);
        Assert.True(firstCorrect.IsInWrongBook);

        var second = Store.StartSession(PracticeMode.WrongBook, seed: 5);
        var secondCorrect = Answer(second, true);
        Assert.Equal(2, secondCorrect.WrongProgressAfter);
        Assert.True(secondCorrect.RemovedFromWrongBook);
        Assert.False(secondCorrect.IsInWrongBook);
        Assert.Equal(0, Store.WrongBookCount());
    }

    [Fact]
    public void WrongAnswerResetsConsecutiveProgress()
    {
        InsertQuestion(1);
        Store.UpdateSettings(new SettingsSnapshot(7, 2));
        Answer(Store.StartSession(PracticeMode.Normal, seed: 1), false);
        Assert.Equal(1, Answer(Store.StartSession(PracticeMode.WrongBook, seed: 2), true).WrongProgressAfter);

        var reset = Answer(Store.StartSession(PracticeMode.WrongBook, seed: 3), false);
        Assert.Equal(1, reset.WrongProgressBefore);
        Assert.Equal(0, reset.WrongProgressAfter);
        Assert.Equal(1, Answer(Store.StartSession(PracticeMode.WrongBook, seed: 4), true).WrongProgressAfter);
        Assert.Equal(1, Store.WrongBookCount());
    }

    [Fact]
    public void OneSubmissionTokenWritesExactlyOneAttempt()
    {
        InsertQuestion(1);
        InsertQuestion(2);
        var session = Store.StartSession(PracticeMode.Normal, seed: 8);
        var item = Assert.IsType<PracticeQuestion>(session.CurrentItem);
        var selected = OptionIDs(item, false);
        var request = new SubmitAnswerRequest(session.Id, item.ItemID, selected, "fixed-token");
        var first = Store.Submit(request);
        var retry = Store.Submit(request);

        Assert.Equal(first.AttemptID, retry.AttemptID);
        Assert.Equal(first.Session.Id, retry.Session.Id);
        Assert.Equal(first.Session.CurrentIndex, retry.Session.CurrentIndex);
        Assert.True(first.SelectedOptionIDs.SetEquals(retry.SelectedOptionIDs));
        Assert.Equal(1, first.Session.CurrentIndex);
        Assert.Equal(1, ScalarInt("SELECT COUNT(*) FROM attempts"));
        Assert.Equal(1, ScalarInt("SELECT total_attempts FROM question_state WHERE question_id = (SELECT question_id FROM attempts LIMIT 1)"));
    }

    [Fact]
    public void CaptureHashIsIdempotentAndNewCaptureReaddsRemovedQuestion()
    {
        Store.UpdateSettings(new SettingsSnapshot(7, 1));
        var first = CapturedQuestion("image-hash-1");
        var inserted = Store.ImportCapturedQuestion(first);
        Assert.Equal(QuestionImportStatus.Inserted, inserted.Status);
        Assert.True(inserted.AddedToWrongBook);

        var duplicate = Store.ImportCapturedQuestion(first);
        Assert.Equal(QuestionImportStatus.Unchanged, duplicate.Status);
        Assert.False(duplicate.AddedToWrongBook);
        Assert.Equal(1, ScalarInt("SELECT COUNT(*) FROM capture_events"));

        var correction = Store.StartSession(PracticeMode.WrongBook, seed: 9);
        Assert.True(Answer(correction, true).RemovedFromWrongBook);
        var newEvent = Store.ImportCapturedQuestion(CapturedQuestion("image-hash-2"));
        Assert.Equal(QuestionImportStatus.Updated, newEvent.Status);
        Assert.True(newEvent.AddedToWrongBook);
        Assert.Equal(2, ScalarInt("SELECT COUNT(*) FROM capture_events"));
        Assert.Equal(1, Store.WrongBookCount());
    }

    [Fact]
    public void CorrectButUnsureIsRecordedAsWrongBookItem()
    {
        InsertQuestion(1);
        var session = Store.StartSession(PracticeMode.Normal, seed: 7);
        var result = Answer(session, true, markUnsure: true);
        Assert.True(result.IsCorrect);
        Assert.True(result.MarkedAsUnsure);
        Assert.True(result.IsInWrongBook);
        Assert.Equal(0, result.WrongProgressAfter);
    }

    [Fact]
    public async Task TwoApplicationsCanMigrateOneNewDatabaseConcurrently()
    {
        _store?.Dispose();
        _store = null;
        if (Directory.Exists(_directory)) Directory.Delete(_directory, true);

        var tasks = Enumerable.Range(0, 6).Select(index => Task.Run(() =>
        {
            using var opened = new QuestionBankStore(_databasePath, $"app-{index}");
            Assert.Equal(7, opened.Settings().NormalReviewIntervalDays);
        }));
        await Task.WhenAll(tasks);

        _store = new QuestionBankStore(_databasePath, "tests");
        Assert.Equal(2, ScalarInt("SELECT MAX(version) FROM schema_migrations"));
    }

    [Fact]
    public void AttemptsCannotBeUpdatedOrDeleted()
    {
        InsertQuestion(1);
        Answer(Store.StartSession(PracticeMode.Normal, seed: 10), true);
        using var connection = OpenConnection();
        using var update = connection.CreateCommand();
        update.CommandText = "UPDATE attempts SET is_correct = 0";
        Assert.Throws<SqliteException>(() => update.ExecuteNonQuery());
        using var delete = connection.CreateCommand();
        delete.CommandText = "DELETE FROM attempts";
        Assert.Throws<SqliteException>(() => delete.ExecuteNonQuery());
        Assert.Equal(1, ScalarInt("SELECT COUNT(*) FROM attempts"));
    }

    [Fact]
    public void SchemaAndSnapshotJsonRemainCompatibleWithTheMacDatabase()
    {
        InsertQuestion(1);
        var session = Store.StartSession(PracticeMode.Normal, seed: 11);
        var tableNames = QueryStrings("SELECT name FROM sqlite_master WHERE type = 'table'");
        var required = new[]
        {
            "questions", "options", "attempts", "question_state", "practice_sessions",
            "session_items", "capture_events", "settings", "change_log"
        };
        Assert.All(required, name => Assert.Contains(name, tableNames));

        var snapshot = QueryString("SELECT question_snapshot_json FROM session_items WHERE session_id = $id", session.Id);
        Assert.Contains("\"stem\"", snapshot);
        Assert.Contains("\"type\":\"single_choice\"", snapshot);
        Assert.Contains("\"originalLabel\"", snapshot);
        Assert.DoesNotContain("Stem", snapshot);
    }

    public void Dispose()
    {
        _store?.Dispose();
        if (Directory.Exists(_directory)) Directory.Delete(_directory, true);
    }

    private QuestionBankStore Store => _store ?? throw new InvalidOperationException("Store is closed");

    private void RestartStore()
    {
        _store?.Dispose();
        _store = new QuestionBankStore(_databasePath, "restarted-tests");
    }

    private void InsertQuestion(int number) => Store.UpsertQuestion(new QuestionDraft(
        $"question-{number}",
        $"测试题 {number}",
        QuestionType.SingleChoice,
        new[]
        {
            new OptionDraft("A", $"错误选项 {number}", false),
            new OptionDraft("B", $"正确选项 {number}", true),
            new OptionDraft("C", $"干扰选项 {number}", false)
        },
        $"解析 {number}",
        new[] { $"知识点 {number}" }));

    private static CapturedQuestionDraft CapturedQuestion(string hash) => new(
        "captured-question",
        "截图题干",
        new[]
        {
            new CapturedQuestionOption("A", "错误"),
            new CapturedQuestionOption("B", "正确")
        },
        new HashSet<string> { "B" },
        "截图解析",
        new[] { "截图知识点" },
        Path.Combine(Path.GetTempPath(), $"{hash}.png"),
        hash,
        DateTimeOffset.FromUnixTimeSeconds(1_800_000_000));

    private SubmissionResult Answer(
        PracticeSessionSnapshot session,
        bool correct,
        bool markUnsure = false,
        DateTimeOffset? at = null)
    {
        var item = Assert.IsType<PracticeQuestion>(session.CurrentItem);
        return Store.Submit(new SubmitAnswerRequest(
            session.Id,
            item.ItemID,
            OptionIDs(item, correct),
            MarkAsUnsure: markUnsure,
            SubmittedAt: at));
    }

    private static IReadOnlySet<string> OptionIDs(PracticeQuestion item, bool correct)
    {
        var label = correct ? "B" : "A";
        return new HashSet<string> { Assert.Single(item.Options, option => option.OriginalLabel == label).Id };
    }

    private SqliteConnection OpenConnection()
    {
        var connection = new SqliteConnection($"Data Source={_databasePath};Mode=ReadWrite");
        connection.Open();
        return connection;
    }

    private int ScalarInt(string sql)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt32(command.ExecuteScalar());
    }

    private string QueryString(string sql, string id)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.Parameters.AddWithValue("$id", id);
        return Convert.ToString(command.ExecuteScalar()) ?? string.Empty;
    }

    private HashSet<string> QueryStrings(string sql)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        using var reader = command.ExecuteReader();
        var values = new HashSet<string>(StringComparer.Ordinal);
        while (reader.Read()) values.Add(reader.GetString(0));
        return values;
    }
}
