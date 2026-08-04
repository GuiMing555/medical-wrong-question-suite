using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace MedicalQuestionSuite.Core;

internal sealed record SessionPayload(
    [property: JsonPropertyName("stem")] string Stem,
    [property: JsonPropertyName("type")] QuestionType Type,
    [property: JsonPropertyName("explanation")] string Explanation,
    [property: JsonPropertyName("options")] IReadOnlyList<PracticeOption> Options);

public sealed class QuestionBankStore : IDisposable
{
    private readonly SqliteDatabase _database;
    private readonly object _gate = new();
    private bool _disposed;

    public QuestionBankStore(string? databasePath = null, string sourceApplication = "question-bank")
    {
        DatabasePath = Path.GetFullPath(databasePath ?? DatabasePaths.DefaultDatabasePath);
        SourceApplication = sourceApplication;
        _database = new SqliteDatabase(DatabasePath);
        Schema.Migrate(_database);
    }

    public string DatabasePath { get; }
    public string SourceApplication { get; }
    public event EventHandler? DatabaseChanged;

    public void Migrate()
    {
        lock (_gate) Schema.Migrate(_database);
    }

    public SettingsSnapshot Settings()
    {
        lock (_gate) return ReadSettings();
    }

    public void UpdateSettings(SettingsSnapshot settings)
    {
        if (settings.NormalReviewIntervalDays < 0)
            throw Error(QuestionBankErrorCode.InvalidSettings, "复习间隔不能小于 0 天");
        if (settings.WrongRequiredConsecutiveCorrect <= 0)
            throw Error(QuestionBankErrorCode.InvalidSettings, "错题移出次数必须大于 0");
        if (settings.QuestionsPerSession is <= 0)
            throw Error(QuestionBankErrorCode.InvalidSettings, "每轮题数必须大于 0，不限制时请使用 null");

        lock (_gate)
        {
            _database.Transaction(() =>
            {
                _database.Execute("""
                    UPDATE settings SET normal_review_interval_days = $p1,
                        wrong_required_consecutive_correct = $p2, questions_per_session = $p3,
                        updated_at = $p4 WHERE id = 1
                    """,
                    settings.NormalReviewIntervalDays,
                    settings.WrongRequiredConsecutiveCorrect,
                    settings.QuestionsPerSession,
                    NowSeconds());
                AppendChange("settings", "1", "updated");
            });
        }
        NotifyChange();
    }

    public QuestionImportResult UpsertQuestion(QuestionDraft draft)
    {
        Validate(draft);
        QuestionImportResult result;
        lock (_gate)
        {
            result = _database.Transaction(() => UpsertQuestionInsideTransaction(draft));
        }
        if (result.Status != QuestionImportStatus.Unchanged) NotifyChange();
        return result;
    }

    public QuestionImportResult ImportCapturedQuestion(CapturedQuestionDraft captured, bool markWrong = true)
    {
        var normalizedCorrect = captured.CorrectLabels.Select(NormalizeLabel).ToHashSet(StringComparer.Ordinal);
        var options = captured.Options.Select(option => new OptionDraft(
            NormalizeLabel(option.OriginalLabel),
            option.Text,
            normalizedCorrect.Contains(NormalizeLabel(option.OriginalLabel)))).ToArray();
        var draft = new QuestionDraft(
            captured.StableExternalID,
            captured.Stem,
            normalizedCorrect.Count > 1 ? QuestionType.MultipleChoice : QuestionType.SingleChoice,
            options,
            captured.Explanation,
            captured.KnowledgePoints,
            captured.Source,
            captured.SourceImagePath,
            captured.SourceImageHash,
            captured.CapturedAt);
        Validate(draft);
        if (string.IsNullOrWhiteSpace(captured.SourceImageHash))
            throw Error(QuestionBankErrorCode.InvalidQuestion, "截图导入必须包含 sourceImageHash");

        QuestionImportResult result;
        lock (_gate)
        {
            result = _database.Transaction(() =>
            {
                var existingEvent = _database.Rows(
                    "SELECT question_id FROM capture_events WHERE source_image_hash = $p1 LIMIT 1",
                    captured.SourceImageHash).FirstOrDefault();
                if (existingEvent is not null)
                {
                    return new QuestionImportResult(
                        existingEvent.Text("question_id") ?? string.Empty,
                        QuestionImportStatus.Unchanged,
                        false);
                }

                var imported = UpsertQuestionInsideTransaction(draft);
                _database.Execute("""
                    INSERT INTO capture_events(id, source_image_hash, question_id, source_image_path, captured_at, imported_at)
                    VALUES ($p1, $p2, $p3, $p4, $p5, $p6)
                    """,
                    Guid.NewGuid().ToString(),
                    captured.SourceImageHash,
                    imported.QuestionID,
                    captured.SourceImagePath,
                    ToUnixSeconds(captured.CapturedAt),
                    NowSeconds());

                var added = false;
                if (markWrong)
                {
                    var state = StateRow(imported.QuestionID);
                    added = state?.Int32("is_wrong_book") != 1;
                    EnsureWrongBook(imported.QuestionID, captured.CapturedAt, true);
                    AppendChange("wrong_book", imported.QuestionID, "capture_added");
                }

                return new QuestionImportResult(
                    imported.QuestionID,
                    imported.Status == QuestionImportStatus.Unchanged ? QuestionImportStatus.Updated : imported.Status,
                    added);
            });
        }
        if (result.Status != QuestionImportStatus.Unchanged) NotifyChange();
        return result;
    }

    public void MarkQuestionAsUnsure(string questionID, DateTimeOffset? at = null)
    {
        lock (_gate)
        {
            _database.Transaction(() =>
            {
                if (_database.ScalarInt(
                        "SELECT COUNT(*) FROM questions WHERE id = $p1 AND active = 1",
                        questionID) != 1)
                    throw Error(QuestionBankErrorCode.InvalidQuestion, "题目不存在");
                EnsureWrongBook(questionID, at ?? DateTimeOffset.Now, true);
                AppendChange("wrong_book", questionID, "manually_added");
            });
        }
        NotifyChange();
    }

    public int WrongBookCount()
    {
        lock (_gate) return _database.ScalarInt("SELECT COUNT(*) FROM question_state WHERE is_wrong_book = 1");
    }

    public DashboardSnapshot Dashboard(DateTimeOffset? now = null)
    {
        lock (_gate)
        {
            var timestamp = now ?? DateTimeOffset.Now;
            var settings = ReadSettings();
            var startOfDay = new DateTimeOffset(timestamp.Year, timestamp.Month, timestamp.Day, 0, 0, 0, timestamp.Offset);
            var total = _database.ScalarInt("SELECT COUNT(*) FROM questions WHERE active = 1");
            var unseen = _database.ScalarInt("""
                SELECT COUNT(*) FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
                """);
            var due = _database.ScalarInt("""
                SELECT COUNT(*) FROM questions q JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND s.total_attempts > 0 AND s.last_answered_at <= $p1
                """, ToUnixSeconds(timestamp.AddDays(-settings.NormalReviewIntervalDays)));
            var wrong = _database.ScalarInt("SELECT COUNT(*) FROM question_state WHERE is_wrong_book = 1");
            var today = _database.ScalarInt(
                "SELECT COUNT(*) FROM attempts WHERE submitted_at >= $p1",
                ToUnixSeconds(startOfDay));
            return new DashboardSnapshot(total, unseen, due, wrong, today, ActiveSessionSummary());
        }
    }

    public PracticeSessionSnapshot StartSession(
        PracticeMode mode,
        int? limit = null,
        DateTimeOffset? now = null,
        ulong? seed = null,
        bool resumeExisting = true)
    {
        PracticeSessionSnapshot result;
        lock (_gate)
        {
            result = _database.Transaction(() =>
            {
                if (resumeExisting)
                {
                    var active = _database.Rows("""
                        SELECT id FROM practice_sessions
                        WHERE mode = $p1 AND status = 'active'
                        ORDER BY updated_at DESC LIMIT 1
                        """, ModeValue(mode)).FirstOrDefault();
                    if (active?.Text("id") is { } activeID) return SessionSnapshot(activeID);
                }

                var settings = ReadSettings();
                var requestedLimit = limit ?? settings.QuestionsPerSession;
                if (requestedLimit is <= 0)
                    throw Error(QuestionBankErrorCode.InvalidSettings, "每轮题数必须大于 0");

                var timestamp = now ?? DateTimeOffset.Now;
                List<IReadOnlyDictionary<string, object?>> candidates;
                if (mode == PracticeMode.Normal)
                {
                    var cutoff = ToUnixSeconds(timestamp.AddDays(-settings.NormalReviewIntervalDays));
                    candidates = _database.Rows("""
                        SELECT q.id FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND (s.last_answered_at IS NULL OR s.last_answered_at <= $p1)
                        ORDER BY q.id
                        """, cutoff);
                }
                else
                {
                    candidates = _database.Rows("""
                        SELECT q.id FROM questions q JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND s.is_wrong_book = 1 ORDER BY q.id
                        """);
                }

                var questionIDs = candidates.Select(row => row.Text("id"))
                    .Where(value => value is not null)
                    .Cast<string>()
                    .ToList();
                if (questionIDs.Count == 0)
                    throw Error(
                        QuestionBankErrorCode.NoEligibleQuestions,
                        mode == PracticeMode.WrongBook ? "错题本为空" : "当前没有待练习的题目",
                        mode);

                var actualSeed = seed ?? NewSeed();
                var random = new SplitMix64(actualSeed);
                Shuffle(questionIDs, ref random);
                if (requestedLimit is { } count && questionIDs.Count > count)
                    questionIDs = questionIDs.Take(count).ToList();

                var sessionID = Guid.NewGuid().ToString();
                var time = ToUnixSeconds(timestamp);
                _database.Execute("""
                    INSERT INTO practice_sessions(id, mode, status, current_index, total_items, random_seed, created_at, updated_at)
                    VALUES ($p1, $p2, 'active', 0, $p3, $p4, $p5, $p6)
                    """,
                    sessionID,
                    ModeValue(mode),
                    questionIDs.Count,
                    unchecked((long)actualSeed),
                    time,
                    time);

                for (var position = 0; position < questionIDs.Count; position++)
                {
                    var questionID = questionIDs[position];
                    var question = _database.Rows(
                        "SELECT stem, question_type, explanation FROM questions WHERE id = $p1",
                        questionID).First();
                    var optionRows = _database.Rows("""
                        SELECT id, text, original_label, is_correct FROM options
                        WHERE question_id = $p1 AND active = 1 ORDER BY sort_order, id
                        """, questionID);
                    var options = optionRows.Select(row => new PracticeOption(
                        row.Text("id") ?? string.Empty,
                        row.Text("text") ?? string.Empty,
                        row.Text("original_label"))).ToList();
                    Shuffle(options, ref random);
                    var correctIDs = optionRows
                        .Where(row => row.Int32("is_correct") == 1)
                        .Select(row => row.Text("id") ?? string.Empty)
                        .ToArray();
                    var payload = new SessionPayload(
                        question.Text("stem") ?? string.Empty,
                        ParseQuestionType(question.Text("question_type")),
                        question.Text("explanation") ?? string.Empty,
                        options);
                    _database.Execute("""
                        INSERT INTO session_items(id, session_id, question_id, position, question_snapshot_json,
                            option_order_json, correct_option_ids_json)
                        VALUES ($p1, $p2, $p3, $p4, $p5, $p6, $p7)
                        """,
                        Guid.NewGuid().ToString(),
                        sessionID,
                        questionID,
                        position,
                        JsonSupport.Serialize(payload),
                        JsonSupport.Serialize(options.Select(option => option.Id).ToArray()),
                        JsonSupport.Serialize(correctIDs));
                }

                AppendChange(
                    "practice_session",
                    sessionID,
                    "started",
                    JsonSupport.Serialize(new Dictionary<string, string> { ["mode"] = ModeValue(mode) }));
                return SessionSnapshot(sessionID);
            });
        }
        NotifyChange();
        return result;
    }

    public PracticeSessionSnapshot? CurrentSession(PracticeMode? mode = null)
    {
        lock (_gate)
        {
            var sql = "SELECT id FROM practice_sessions WHERE status = 'active'";
            var arguments = new List<object?>();
            if (mode is { } actualMode)
            {
                sql += " AND mode = $p1";
                arguments.Add(ModeValue(actualMode));
            }
            sql += " ORDER BY updated_at DESC LIMIT 1";
            var id = _database.Rows(sql, arguments.ToArray()).FirstOrDefault()?.Text("id");
            return id is null ? null : SessionSnapshot(id);
        }
    }

    public PracticeSessionSnapshot Session(string id)
    {
        lock (_gate) return SessionSnapshot(id);
    }

    public SubmissionResult Submit(SubmitAnswerRequest request)
    {
        SubmissionResult result;
        var changed = false;
        lock (_gate)
        {
            result = _database.Transaction(() =>
            {
                var existing = _database.Rows("""
                    SELECT session_id, session_item_id, result_json FROM attempts
                    WHERE submission_token = $p1 LIMIT 1
                    """, request.EffectiveSubmissionToken).FirstOrDefault();
                if (existing is not null)
                {
                    if (existing.Text("session_id") != request.SessionID || existing.Text("session_item_id") != request.ItemID)
                        throw Error(QuestionBankErrorCode.InvalidSelection, "提交标识已用于其他题目");
                    var json = existing.Text("result_json")
                        ?? throw Error(QuestionBankErrorCode.Database, "幂等记录缺少结果快照");
                    return JsonSupport.Deserialize<SubmissionResult>(json);
                }

                var sessionRow = _database.Rows("""
                    SELECT mode, status, current_index, total_items FROM practice_sessions WHERE id = $p1
                    """, request.SessionID).FirstOrDefault()
                    ?? throw Error(QuestionBankErrorCode.SessionNotFound, "练习记录不存在");
                if (sessionRow.Text("status") != "active")
                    throw Error(QuestionBankErrorCode.SessionCompleted, "本轮练习已完成");

                var itemRow = _database.Rows("""
                    SELECT id, question_id, position, question_snapshot_json, option_order_json,
                        correct_option_ids_json, answered_at
                    FROM session_items WHERE id = $p1 AND session_id = $p2
                    """, request.ItemID, request.SessionID).FirstOrDefault()
                    ?? throw Error(QuestionBankErrorCode.SessionItemNotFound, "本轮中不存在该题");
                if (itemRow.TryGetValue("answered_at", out var answeredAt) && answeredAt is not null)
                    throw Error(QuestionBankErrorCode.ItemAlreadyAnswered, "该题已提交");
                if (itemRow.Int32("position") != sessionRow.Int32("current_index"))
                    throw Error(QuestionBankErrorCode.ItemIsNotCurrent, "只能提交当前题");

                var payload = JsonSupport.Deserialize<SessionPayload>(itemRow.Text("question_snapshot_json") ?? "");
                var allowed = payload.Options.Select(option => option.Id).ToHashSet(StringComparer.Ordinal);
                var selected = request.SelectedOptionIDs.ToHashSet(StringComparer.Ordinal);
                if (selected.Count == 0 || !selected.IsSubsetOf(allowed))
                    throw Error(QuestionBankErrorCode.InvalidSelection, "所选选项不属于当前题");
                var correct = JsonSupport.Deserialize<string[]>(itemRow.Text("correct_option_ids_json") ?? "[]")
                    .ToHashSet(StringComparer.Ordinal);
                var isCorrect = selected.SetEquals(correct);
                var effectiveWrong = !isCorrect || request.MarkAsUnsure;
                var questionID = itemRow.Text("question_id") ?? string.Empty;
                var state = StateRow(questionID);
                var wasWrong = state?.Int32("is_wrong_book") == 1;
                var progressBefore = state?.Int32("consecutive_correct") ?? 0;
                var required = ReadSettings().WrongRequiredConsecutiveCorrect;
                var isWrong = wasWrong;
                var progressAfter = progressBefore;
                var removed = false;
                if (effectiveWrong)
                {
                    isWrong = true;
                    progressAfter = 0;
                }
                else if (wasWrong)
                {
                    progressAfter++;
                    if (progressAfter >= required)
                    {
                        isWrong = false;
                        removed = true;
                    }
                }
                else
                {
                    progressAfter = 0;
                }

                var submittedAt = ToUnixSeconds(request.EffectiveSubmittedAt);
                _database.Execute("""
                    INSERT INTO question_state(question_id, last_answered_at, total_attempts, correct_attempts,
                        wrong_attempts, is_wrong_book, consecutive_correct, added_to_wrong_at, removed_from_wrong_at, updated_at)
                    VALUES ($p1, $p2, 1, $p3, $p4, $p5, $p6, $p7, $p8, $p9)
                    ON CONFLICT(question_id) DO UPDATE SET
                        last_answered_at = excluded.last_answered_at,
                        total_attempts = question_state.total_attempts + 1,
                        correct_attempts = question_state.correct_attempts + excluded.correct_attempts,
                        wrong_attempts = question_state.wrong_attempts + excluded.wrong_attempts,
                        is_wrong_book = excluded.is_wrong_book,
                        consecutive_correct = excluded.consecutive_correct,
                        added_to_wrong_at = CASE
                            WHEN excluded.is_wrong_book = 1 AND question_state.is_wrong_book = 0 THEN excluded.added_to_wrong_at
                            ELSE question_state.added_to_wrong_at END,
                        removed_from_wrong_at = CASE
                            WHEN excluded.is_wrong_book = 0 AND question_state.is_wrong_book = 1 THEN excluded.removed_from_wrong_at
                            ELSE question_state.removed_from_wrong_at END,
                        updated_at = excluded.updated_at
                    """,
                    questionID,
                    submittedAt,
                    isCorrect ? 1 : 0,
                    effectiveWrong ? 1 : 0,
                    isWrong ? 1 : 0,
                    progressAfter,
                    isWrong ? submittedAt : null,
                    removed ? submittedAt : null,
                    submittedAt);

                var attemptID = Guid.NewGuid().ToString();
                var mode = ParsePracticeMode(sessionRow.Text("mode"));
                var nextIndex = sessionRow.Int32("current_index") + 1;
                var total = sessionRow.Int32("total_items");
                var complete = nextIndex >= total;
                _database.Execute("""
                    UPDATE practice_sessions SET current_index = $p1, status = $p2,
                        updated_at = $p3, completed_at = $p4 WHERE id = $p5
                    """,
                    nextIndex,
                    complete ? "completed" : "active",
                    submittedAt,
                    complete ? submittedAt : null,
                    request.SessionID);

                var session = SessionSnapshot(request.SessionID);
                var answer = new SubmissionResult(
                    attemptID,
                    isCorrect,
                    correct,
                    selected,
                    payload.Explanation,
                    request.MarkAsUnsure,
                    isWrong,
                    progressBefore,
                    progressAfter,
                    removed,
                    session);
                _database.Execute("""
                    INSERT INTO attempts(id, submission_token, session_id, session_item_id, question_id, mode,
                        submitted_at, selected_option_ids_json, displayed_option_order_json, correct_option_ids_json,
                        is_correct, marked_unsure, was_in_wrong_book, is_in_wrong_book, wrong_progress_before,
                        wrong_progress_after, removed_from_wrong_book, explanation_snapshot, result_json)
                    VALUES ($p1, $p2, $p3, $p4, $p5, $p6, $p7, $p8, $p9, $p10,
                        $p11, $p12, $p13, $p14, $p15, $p16, $p17, $p18, $p19)
                    """,
                    attemptID,
                    request.EffectiveSubmissionToken,
                    request.SessionID,
                    request.ItemID,
                    questionID,
                    ModeValue(mode),
                    submittedAt,
                    JsonSupport.Serialize(selected.OrderBy(id => id, StringComparer.Ordinal).ToArray()),
                    itemRow.Text("option_order_json") ?? "[]",
                    JsonSupport.Serialize(correct.OrderBy(id => id, StringComparer.Ordinal).ToArray()),
                    isCorrect ? 1 : 0,
                    request.MarkAsUnsure ? 1 : 0,
                    wasWrong ? 1 : 0,
                    isWrong ? 1 : 0,
                    progressBefore,
                    progressAfter,
                    removed ? 1 : 0,
                    payload.Explanation,
                    JsonSupport.Serialize(answer));
                _database.Execute(
                    "UPDATE session_items SET answered_at = $p1, attempt_id = $p2 WHERE id = $p3",
                    submittedAt,
                    attemptID,
                    request.ItemID);
                AppendChange(
                    "attempt",
                    attemptID,
                    "submitted",
                    JsonSupport.Serialize(new Dictionary<string, string> { ["questionID"] = questionID }));
                AppendChange("wrong_book", questionID, isWrong ? "active" : "inactive");
                changed = true;
                return answer;
            });
        }
        if (changed) NotifyChange();
        return result;
    }

    public IReadOnlyList<ChangeLogEntry> Changes(long afterSequence = 0, int limit = 500)
    {
        lock (_gate)
        {
            return _database.Rows("""
                SELECT sequence, source_app, entity_type, entity_id, action, payload_json, created_at
                FROM change_log WHERE sequence > $p1 ORDER BY sequence LIMIT $p2
                """, afterSequence, Math.Max(1, limit)).Select(row => new ChangeLogEntry(
                    row.Int64("sequence"),
                    row.Text("source_app") ?? string.Empty,
                    row.Text("entity_type") ?? string.Empty,
                    row.Text("entity_id") ?? string.Empty,
                    row.Text("action") ?? string.Empty,
                    row.Text("payload_json"),
                    FromUnixSeconds(row.Double("created_at")))).ToArray();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _database.Dispose();
            _disposed = true;
        }
    }

    private static void Validate(QuestionDraft draft)
    {
        if (string.IsNullOrWhiteSpace(draft.StableExternalID))
            throw Error(QuestionBankErrorCode.InvalidQuestion, "stableExternalID 不能为空");
        if (string.IsNullOrWhiteSpace(draft.Stem))
            throw Error(QuestionBankErrorCode.InvalidQuestion, "题干不能为空");
        if (draft.Options.Count < 2)
            throw Error(QuestionBankErrorCode.InvalidQuestion, "每题至少需要 2 个选项");
        if (draft.Options.Any(option => string.IsNullOrWhiteSpace(option.Text)))
            throw Error(QuestionBankErrorCode.InvalidQuestion, "选项内容不能为空");
        var correctCount = draft.Options.Count(option => option.IsCorrect);
        if (correctCount == 0)
            throw Error(QuestionBankErrorCode.InvalidQuestion, "至少需要一个正确选项");
        if (draft.Type == QuestionType.SingleChoice && correctCount != 1)
            throw Error(QuestionBankErrorCode.InvalidQuestion, "单选题必须且只能有一个正确选项");
    }

    private SettingsSnapshot ReadSettings()
    {
        var row = _database.Rows("SELECT * FROM settings WHERE id = 1").FirstOrDefault()
            ?? throw Error(QuestionBankErrorCode.Database, "设置记录不存在");
        return new SettingsSnapshot(
            row.Int32("normal_review_interval_days", 7),
            row.Int32("wrong_required_consecutive_correct", 3),
            row.TryGetValue("questions_per_session", out var value) && value is not null ? Convert.ToInt32(value) : null);
    }

    private QuestionImportResult UpsertQuestionInsideTransaction(QuestionDraft draft)
    {
        var now = NowSeconds();
        var existing = _database.Rows(
            "SELECT * FROM questions WHERE external_id = $p1 LIMIT 1",
            draft.StableExternalID).FirstOrDefault();
        var questionID = existing?.Text("id") ?? draft.Id ?? Guid.NewGuid().ToString();
        var oldOptions = _database.Rows("""
            SELECT id, original_label, text, is_correct, sort_order FROM options
            WHERE question_id = $p1 AND active = 1 ORDER BY sort_order
            """, questionID);
        var same = existing is not null
            && existing.Text("stem") == draft.Stem
            && existing.Text("question_type") == QuestionTypeValue(draft.Type)
            && existing.Text("explanation") == draft.Explanation
            && existing.Text("source") == draft.Source
            && existing.Text("source_image_path") == draft.SourceImagePath
            && existing.Text("source_image_hash") == draft.SourceImageHash
            && oldOptions.Count == draft.Options.Count;
        if (same)
        {
            for (var index = 0; index < oldOptions.Count; index++)
            {
                var oldOption = oldOptions[index];
                var option = draft.Options[index];
                if (oldOption.Text("original_label") != option.OriginalLabel
                    || oldOption.Text("text") != option.Text
                    || oldOption.Int32("is_correct") != (option.IsCorrect ? 1 : 0)
                    || oldOption.Int32("sort_order") != index)
                {
                    same = false;
                    break;
                }
            }
        }

        var status = existing is null
            ? QuestionImportStatus.Inserted
            : same ? QuestionImportStatus.Unchanged : QuestionImportStatus.Updated;
        _database.Execute("""
            INSERT INTO questions(id, external_id, stem, question_type, explanation, source, source_image_path,
                source_image_hash, captured_at, active, created_at, updated_at)
            VALUES ($p1, $p2, $p3, $p4, $p5, $p6, $p7, $p8, $p9, 1, $p10, $p11)
            ON CONFLICT(external_id) DO UPDATE SET stem = excluded.stem,
                question_type = excluded.question_type, explanation = excluded.explanation,
                source = excluded.source, source_image_path = excluded.source_image_path,
                source_image_hash = excluded.source_image_hash, captured_at = excluded.captured_at,
                active = 1, updated_at = excluded.updated_at
            """,
            questionID,
            draft.StableExternalID,
            draft.Stem,
            QuestionTypeValue(draft.Type),
            draft.Explanation,
            draft.Source,
            draft.SourceImagePath,
            draft.SourceImageHash,
            draft.CapturedAt is null ? null : ToUnixSeconds(draft.CapturedAt.Value),
            now,
            now);
        _database.Execute(
            "UPDATE options SET active = 0, updated_at = $p1 WHERE question_id = $p2",
            now,
            questionID);
        for (var index = 0; index < draft.Options.Count; index++)
        {
            var option = draft.Options[index];
            var optionID = option.Id ?? StableID(
                "opt",
                $"{draft.StableExternalID}|{option.OriginalLabel ?? string.Empty}|{NormalizeText(option.Text)}");
            _database.Execute("""
                INSERT INTO options(id, question_id, original_label, text, is_correct, sort_order, active, created_at, updated_at)
                VALUES ($p1, $p2, $p3, $p4, $p5, $p6, 1, $p7, $p8)
                ON CONFLICT(id) DO UPDATE SET original_label = excluded.original_label,
                    text = excluded.text, is_correct = excluded.is_correct,
                    sort_order = excluded.sort_order, active = 1, updated_at = excluded.updated_at
                """,
                optionID,
                questionID,
                option.OriginalLabel,
                option.Text,
                option.IsCorrect ? 1 : 0,
                index,
                now,
                now);
        }

        _database.Execute("DELETE FROM question_knowledge_points WHERE question_id = $p1", questionID);
        foreach (var point in draft.KnowledgePoints ?? Array.Empty<string>())
        {
            var normalized = NormalizeText(point);
            if (normalized.Length == 0) continue;
            var pointID = StableID("kp", normalized);
            _database.Execute("""
                INSERT OR IGNORE INTO knowledge_points(id, normalized_name, display_name, created_at)
                VALUES ($p1, $p2, $p3, $p4)
                """, pointID, normalized, point, now);
            _database.Execute("""
                INSERT OR IGNORE INTO question_knowledge_points(question_id, knowledge_point_id)
                VALUES ($p1, $p2)
                """, questionID, pointID);
        }
        AppendChange("question", questionID, ImportStatusValue(status));
        return new QuestionImportResult(questionID, status, false);
    }

    private PracticeSessionSnapshot SessionSnapshot(string id)
    {
        var row = _database.Rows("""
            SELECT id, mode, status, current_index, total_items FROM practice_sessions WHERE id = $p1
            """, id).FirstOrDefault()
            ?? throw Error(QuestionBankErrorCode.SessionNotFound, "练习记录不存在");
        var mode = ParsePracticeMode(row.Text("mode"));
        var current = row.Int32("current_index");
        var total = row.Int32("total_items");
        var complete = row.Text("status") == "completed";
        var summary = new PracticeSessionSummary(id, mode, current, total, current, complete);
        if (complete) return new PracticeSessionSnapshot(summary, null);

        var item = _database.Rows("""
            SELECT id, question_id, question_snapshot_json FROM session_items
            WHERE session_id = $p1 AND position = $p2 LIMIT 1
            """, id, current).FirstOrDefault();
        if (item is null) return new PracticeSessionSnapshot(summary, null);
        var payload = JsonSupport.Deserialize<SessionPayload>(item.Text("question_snapshot_json") ?? "");
        var questionID = item.Text("question_id") ?? string.Empty;
        var state = StateRow(questionID);
        var settings = ReadSettings();
        var question = new PracticeQuestion(
            item.Text("id") ?? string.Empty,
            questionID,
            payload.Stem,
            payload.Type,
            payload.Options,
            payload.Explanation,
            state?.Int32("consecutive_correct") ?? 0,
            settings.WrongRequiredConsecutiveCorrect);
        return new PracticeSessionSnapshot(summary, question);
    }

    private PracticeSessionSummary? ActiveSessionSummary()
    {
        var row = _database.Rows("""
            SELECT id, mode, current_index, total_items FROM practice_sessions
            WHERE status = 'active' ORDER BY updated_at DESC LIMIT 1
            """).FirstOrDefault();
        if (row?.Text("id") is not { } id) return null;
        var current = row.Int32("current_index");
        return new PracticeSessionSummary(
            id,
            ParsePracticeMode(row.Text("mode")),
            current,
            row.Int32("total_items"),
            current,
            false);
    }

    private IReadOnlyDictionary<string, object?>? StateRow(string questionID) =>
        _database.Rows("SELECT * FROM question_state WHERE question_id = $p1", questionID).FirstOrDefault();

    private void EnsureWrongBook(string questionID, DateTimeOffset at, bool resetProgress)
    {
        var timestamp = ToUnixSeconds(at);
        _database.Execute("""
            INSERT INTO question_state(question_id, is_wrong_book, consecutive_correct, added_to_wrong_at, updated_at)
            VALUES ($p1, 1, 0, $p2, $p3)
            ON CONFLICT(question_id) DO UPDATE SET is_wrong_book = 1,
                consecutive_correct = CASE WHEN $p4 = 1 THEN 0 ELSE question_state.consecutive_correct END,
                added_to_wrong_at = CASE WHEN question_state.is_wrong_book = 0
                    THEN excluded.added_to_wrong_at ELSE question_state.added_to_wrong_at END,
                updated_at = excluded.updated_at
            """,
            questionID,
            timestamp,
            timestamp,
            resetProgress ? 1 : 0);
    }

    private void AppendChange(string entityType, string entityID, string action, string? payload = null) =>
        _database.Execute("""
            INSERT INTO change_log(source_app, entity_type, entity_id, action, payload_json, created_at)
            VALUES ($p1, $p2, $p3, $p4, $p5, $p6)
            """,
            SourceApplication,
            entityType,
            entityID,
            action,
            payload,
            NowSeconds());

    private void NotifyChange() => DatabaseChanged?.Invoke(this, EventArgs.Empty);

    private static string NormalizeLabel(string value) =>
        value.Trim().Trim('.', '、', ':', '：', '(', ')', '（', '）', '[', ']', '【', '】').ToUpperInvariant();

    private static string NormalizeText(string value) =>
        string.Join(" ", value.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).ToLowerInvariant();

    private static string StableID(string prefix, string source)
    {
        ulong hash = 14_695_981_039_346_656_037;
        foreach (var value in Encoding.UTF8.GetBytes(source))
        {
            hash ^= value;
            hash *= 1_099_511_628_211;
        }
        return $"{prefix}_{hash:x}";
    }

    private static string ModeValue(PracticeMode mode) => mode == PracticeMode.Normal ? "normal" : "wrong_book";
    private static PracticeMode ParsePracticeMode(string? value) => value == "wrong_book" ? PracticeMode.WrongBook : PracticeMode.Normal;
    private static string QuestionTypeValue(QuestionType type) => type == QuestionType.SingleChoice ? "single_choice" : "multiple_choice";
    private static QuestionType ParseQuestionType(string? value) => value == "multiple_choice" ? QuestionType.MultipleChoice : QuestionType.SingleChoice;
    private static string ImportStatusValue(QuestionImportStatus status) => status switch
    {
        QuestionImportStatus.Inserted => "inserted",
        QuestionImportStatus.Updated => "updated",
        _ => "unchanged"
    };

    private static double NowSeconds() => ToUnixSeconds(DateTimeOffset.Now);
    private static double ToUnixSeconds(DateTimeOffset value) => value.ToUnixTimeMilliseconds() / 1000.0;
    private static DateTimeOffset FromUnixSeconds(double value) => DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(value * 1000));

    private static QuestionBankException Error(QuestionBankErrorCode code, string message, PracticeMode? mode = null) =>
        new(code, message, mode);

    private static ulong NewSeed()
    {
        Span<byte> bytes = stackalloc byte[sizeof(ulong)];
        RandomNumberGenerator.Fill(bytes);
        return BitConverter.ToUInt64(bytes);
    }

    private static void Shuffle<T>(IList<T> values, ref SplitMix64 random)
    {
        for (var index = values.Count - 1; index > 0; index--)
        {
            var target = (int)(random.Next() % (ulong)(index + 1));
            (values[index], values[target]) = (values[target], values[index]);
        }
    }

    private struct SplitMix64
    {
        private ulong _state;
        internal SplitMix64(ulong seed) => _state = seed;

        internal ulong Next()
        {
            _state += 0x9E3779B97F4A7C15;
            var value = _state;
            value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9;
            value = (value ^ (value >> 27)) * 0x94D049BB133111EB;
            return value ^ (value >> 31);
        }
    }
}
