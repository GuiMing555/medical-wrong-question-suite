import Foundation

private struct SessionPayload: Codable {
    let stem: String
    let type: QuestionType
    let explanation: String
    let options: [PracticeOption]
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

public final class QuestionBankStore: @unchecked Sendable {
    public let databaseURL: URL
    public let sourceApplication: String

    private let queue = DispatchQueue(label: "com.guiming.medicalquestionbank.database")
    private let db: SQLiteDatabase

    public init(databaseURL: URL, sourceApplication: String = "question-bank") throws {
        self.databaseURL = databaseURL
        self.sourceApplication = sourceApplication
        db = try SQLiteDatabase(url: databaseURL)
        try QuestionBankSchema.migrate(db)
    }

    public convenience init(sourceApplication: String = "question-bank") throws {
        try self.init(databaseURL: QuestionBankPaths.defaultDatabaseURL(), sourceApplication: sourceApplication)
    }

    public func migrate() throws {
        try queue.sync { try QuestionBankSchema.migrate(db) }
    }

    public func settings() throws -> SettingsSnapshot {
        try queue.sync { try readSettings() }
    }

    public func updateSettings(_ settings: SettingsSnapshot) throws {
        guard settings.normalReviewIntervalDays >= 0 else {
            throw QuestionBankError.invalidSettings("复习间隔不能小于 0 天")
        }
        guard settings.wrongRequiredConsecutiveCorrect > 0 else {
            throw QuestionBankError.invalidSettings("错题移出次数必须大于 0")
        }
        if let count = settings.questionsPerSession, count <= 0 {
            throw QuestionBankError.invalidSettings("每轮题数必须大于 0，不限制时请使用 nil")
        }
        try queue.sync {
            try db.transaction {
                try db.execute(
                    """
                    UPDATE settings SET normal_review_interval_days = ?,
                        wrong_required_consecutive_correct = ?, questions_per_session = ?, updated_at = ? WHERE id = 1
                    """,
                    [
                        .integer(Int64(settings.normalReviewIntervalDays)),
                        .integer(Int64(settings.wrongRequiredConsecutiveCorrect)),
                        settings.questionsPerSession.map { .integer(Int64($0)) } ?? .null,
                        .real(Date().timeIntervalSince1970)
                    ]
                )
                try appendChange(entityType: "settings", entityID: "1", action: "updated")
            }
        }
        notifyChange()
    }

    @discardableResult
    public func upsertQuestion(_ draft: QuestionDraft) throws -> QuestionImportResult {
        try validate(draft)
        let result = try queue.sync {
            try db.transaction { try upsertQuestionInsideTransaction(draft) }
        }
        if result.status != .unchanged { notifyChange() }
        return result
    }

    @discardableResult
    public func importCapturedQuestion(
        _ captured: CapturedQuestionDraft,
        markWrong: Bool = true
    ) throws -> QuestionImportResult {
        let normalizedCorrect = Set(captured.correctLabels.map(normalizeLabel))
        let options = captured.options.map { option in
            OptionDraft(
                originalLabel: normalizeLabel(option.originalLabel),
                text: option.text,
                isCorrect: normalizedCorrect.contains(normalizeLabel(option.originalLabel))
            )
        }
        let type: QuestionType = normalizedCorrect.count > 1 ? .multipleChoice : .singleChoice
        let draft = QuestionDraft(
            stableExternalID: captured.stableExternalID,
            stem: captured.stem,
            type: type,
            options: options,
            explanation: captured.explanation,
            knowledgePoints: captured.knowledgePoints,
            source: captured.source,
            sourceImagePath: captured.sourceImagePath,
            sourceImageHash: captured.sourceImageHash,
            capturedAt: captured.capturedAt
        )
        try validate(draft)
        guard !captured.sourceImageHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuestionBankError.invalidQuestion("截图导入必须包含 sourceImageHash")
        }

        let result = try queue.sync {
            try db.transaction {
                if let existing = try db.rows(
                    "SELECT question_id FROM capture_events WHERE source_image_hash = ? LIMIT 1",
                    [.text(captured.sourceImageHash)]
                ).first, let questionID = existing["question_id"]?.string {
                    let refreshed = try upsertQuestionInsideTransaction(draft)
                    return QuestionImportResult(
                        questionID: questionID,
                        status: refreshed.status,
                        addedToWrongBook: false
                    )
                }

                var imported = try upsertQuestionInsideTransaction(draft)
                let now = Date().timeIntervalSince1970
                try db.execute(
                    """
                    INSERT INTO capture_events(id, source_image_hash, question_id, source_image_path, captured_at, imported_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(UUID().uuidString), .text(captured.sourceImageHash), .text(imported.questionID),
                        .text(captured.sourceImagePath), .real(captured.capturedAt.timeIntervalSince1970), .real(now)
                    ]
                )
                var added = false
                if markWrong {
                    let state = try stateRow(questionID: imported.questionID)
                    added = state?["is_wrong_book"]?.int != 1
                    try ensureWrongBook(questionID: imported.questionID, at: captured.capturedAt, resetProgress: true)
                    try appendChange(entityType: "wrong_book", entityID: imported.questionID, action: "capture_added")
                }
                if imported.status == .unchanged {
                    imported = QuestionImportResult(questionID: imported.questionID, status: .updated, addedToWrongBook: added)
                } else {
                    imported = QuestionImportResult(questionID: imported.questionID, status: imported.status, addedToWrongBook: added)
                }
                return imported
            }
        }
        if result.status != .unchanged { notifyChange() }
        return result
    }

    public func markQuestionAsUnsure(questionID: String, at date: Date = Date()) throws {
        try queue.sync {
            try db.transaction {
                guard try db.scalarInt("SELECT COUNT(*) FROM questions WHERE id = ? AND active = 1", [.text(questionID)]) == 1 else {
                    throw QuestionBankError.invalidQuestion("题目不存在")
                }
                try ensureWrongBook(questionID: questionID, at: date, resetProgress: true)
                try appendChange(entityType: "wrong_book", entityID: questionID, action: "manually_added")
            }
        }
        notifyChange()
    }

    public func wrongBookCount() throws -> Int {
        try queue.sync {
            try db.scalarInt("SELECT COUNT(*) FROM question_state WHERE is_wrong_book = 1")
        }
    }

    public func dashboard(now: Date = Date(), calendar: Calendar = .current) throws -> DashboardSnapshot {
        try queue.sync {
            let settings = try readSettings()
            let cutoff = now.addingTimeInterval(-Double(settings.normalReviewIntervalDays) * 86_400).timeIntervalSince1970
            let startOfDay = calendar.startOfDay(for: now).timeIntervalSince1970
            let total = try db.scalarInt("SELECT COUNT(*) FROM questions WHERE active = 1")
            let unseen = try db.scalarInt(
                """
                SELECT COUNT(*) FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
                """
            )
            let due = try db.scalarInt(
                """
                SELECT COUNT(*) FROM questions q JOIN question_state s ON s.question_id = q.id
                WHERE q.active = 1 AND s.total_attempts > 0 AND s.last_answered_at <= ?
                """,
                [.real(cutoff)]
            )
            let wrong = try db.scalarInt("SELECT COUNT(*) FROM question_state WHERE is_wrong_book = 1")
            let answeredToday = try db.scalarInt("SELECT COUNT(*) FROM attempts WHERE submitted_at >= ?", [.real(startOfDay)])
            let active = try activeSessionSummary()
            return DashboardSnapshot(
                totalQuestions: total,
                unseenCount: unseen,
                dueNormalCount: due,
                wrongBookCount: wrong,
                answeredTodayCount: answeredToday,
                activeSession: active
            )
        }
    }

    public func startSession(
        mode: PracticeMode,
        limit: Int? = nil,
        now: Date = Date(),
        seed: UInt64? = nil,
        resumeExisting: Bool = true
    ) throws -> PracticeSessionSnapshot {
        let result = try queue.sync {
            try db.transaction {
                if resumeExisting, let row = try db.rows(
                    "SELECT id FROM practice_sessions WHERE mode = ? AND status = 'active' ORDER BY updated_at DESC LIMIT 1",
                    [.text(mode.rawValue)]
                ).first, let id = row["id"]?.string {
                    return try sessionSnapshot(id: id)
                }

                if mode == .wrongBook {
                    let unseen = try db.scalarInt(
                        """
                        SELECT COUNT(*) FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND (s.question_id IS NULL OR s.total_attempts = 0)
                        """
                    )
                    let wrong = try db.scalarInt(
                        "SELECT COUNT(*) FROM question_state WHERE is_wrong_book = 1"
                    )
                    if wrong == 0 {
                        throw QuestionBankError.noEligibleQuestions(.wrongBook)
                    }
                    if unseen > 0, wrong < 5 {
                        throw QuestionBankError.wrongModeLocked(unseenCount: unseen, wrongCount: wrong)
                    }
                }

                let settings = try readSettings()
                let requestedLimit = limit ?? settings.questionsPerSession
                if let requestedLimit, requestedLimit <= 0 {
                    throw QuestionBankError.invalidSettings("每轮题数必须大于 0")
                }
                let candidateRows: [SQLiteRow]
                switch mode {
                case .normal:
                    let cutoff = now.addingTimeInterval(-Double(settings.normalReviewIntervalDays) * 86_400).timeIntervalSince1970
                    candidateRows = try db.rows(
                        """
                        SELECT q.id FROM questions q LEFT JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND (s.last_answered_at IS NULL OR s.last_answered_at <= ?)
                        ORDER BY q.id
                        """,
                        [.real(cutoff)]
                    )
                case .wrongBook:
                    candidateRows = try db.rows(
                        """
                        SELECT q.id FROM questions q JOIN question_state s ON s.question_id = q.id
                        WHERE q.active = 1 AND s.is_wrong_book = 1 ORDER BY q.id
                        """
                    )
                }
                var questionIDs = candidateRows.compactMap { $0["id"]?.string }
                guard !questionIDs.isEmpty else { throw QuestionBankError.noEligibleQuestions(mode) }

                let actualSeed = seed ?? UInt64.random(in: UInt64.min...UInt64.max)
                var generator = SeededRandomNumberGenerator(seed: actualSeed)
                questionIDs.shuffle(using: &generator)
                if let requestedLimit { questionIDs = Array(questionIDs.prefix(requestedLimit)) }

                let sessionID = UUID().uuidString
                let timestamp = now.timeIntervalSince1970
                try db.execute(
                    """
                    INSERT INTO practice_sessions(id, mode, status, current_index, total_items, random_seed, created_at, updated_at)
                    VALUES (?, ?, 'active', 0, ?, ?, ?, ?)
                    """,
                    [
                        .text(sessionID), .text(mode.rawValue), .integer(Int64(questionIDs.count)),
                        .integer(Int64(bitPattern: actualSeed)), .real(timestamp), .real(timestamp)
                    ]
                )

                for (position, questionID) in questionIDs.enumerated() {
                    guard let question = try db.rows(
                        "SELECT stem, question_type, explanation FROM questions WHERE id = ?",
                        [.text(questionID)]
                    ).first else { continue }
                    let optionRows = try db.rows(
                        """
                        SELECT id, text, original_label, is_correct FROM options
                        WHERE question_id = ? AND active = 1 ORDER BY sort_order, id
                        """,
                        [.text(questionID)]
                    )
                    var options = optionRows.compactMap { row -> PracticeOption? in
                        guard let id = row["id"]?.string, let text = row["text"]?.string else { return nil }
                        return PracticeOption(id: id, text: text, originalLabel: row["original_label"]?.string)
                    }
                    options.shuffle(using: &generator)
                    let correctIDs = optionRows.compactMap { row in
                        row["is_correct"]?.int == 1 ? row["id"]?.string : nil
                    }
                    let type = QuestionType(rawValue: question["question_type"]?.string ?? "") ?? .singleChoice
                    let payload = SessionPayload(
                        stem: question["stem"]?.string ?? "",
                        type: type,
                        explanation: question["explanation"]?.string ?? "",
                        options: options
                    )
                    try db.execute(
                        """
                        INSERT INTO session_items(id, session_id, question_id, position, question_snapshot_json,
                            option_order_json, correct_option_ids_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(UUID().uuidString), .text(sessionID), .text(questionID), .integer(Int64(position)),
                            .text(try encode(payload)), .text(try options.map(\.id).encodedJSONString()),
                            .text(try correctIDs.encodedJSONString())
                        ]
                    )
                }
                try appendChange(entityType: "practice_session", entityID: sessionID, action: "started", payload: "{\"mode\":\"\(mode.rawValue)\"}")
                return try sessionSnapshot(id: sessionID)
            }
        }
        notifyChange()
        return result
    }

    public func currentSession(mode: PracticeMode? = nil) throws -> PracticeSessionSnapshot? {
        try queue.sync {
            var sql = "SELECT id FROM practice_sessions WHERE status = 'active'"
            var bindings: [SQLiteValue] = []
            if let mode {
                sql += " AND mode = ?"
                bindings.append(.text(mode.rawValue))
            }
            sql += " ORDER BY updated_at DESC LIMIT 1"
            guard let id = try db.rows(sql, bindings).first?["id"]?.string else { return nil }
            return try sessionSnapshot(id: id)
        }
    }

    public func session(id: String) throws -> PracticeSessionSnapshot {
        try queue.sync { try sessionSnapshot(id: id) }
    }

    public func submit(_ request: SubmitAnswerRequest) throws -> SubmissionResult {
        let outcome: (result: SubmissionResult, changed: Bool) = try queue.sync {
            try db.transaction {
                if let existing = try db.rows(
                    "SELECT session_id, session_item_id, result_json FROM attempts WHERE submission_token = ? LIMIT 1",
                    [.text(request.submissionToken)]
                ).first {
                    guard existing["session_id"]?.string == request.sessionID,
                          existing["session_item_id"]?.string == request.itemID else {
                        throw QuestionBankError.invalidSelection
                    }
                    guard let json = existing["result_json"]?.string else {
                        throw QuestionBankError.database("幂等记录缺少结果快照")
                    }
                    return (try decode(SubmissionResult.self, from: json), false)
                }

                guard let sessionRow = try db.rows(
                    "SELECT mode, status, current_index, total_items FROM practice_sessions WHERE id = ?",
                    [.text(request.sessionID)]
                ).first else { throw QuestionBankError.sessionNotFound }
                guard sessionRow["status"]?.string == "active" else { throw QuestionBankError.sessionCompleted }
                guard let itemRow = try db.rows(
                    """
                    SELECT id, question_id, position, question_snapshot_json, option_order_json,
                        correct_option_ids_json, answered_at
                    FROM session_items WHERE id = ? AND session_id = ?
                    """,
                    [.text(request.itemID), .text(request.sessionID)]
                ).first else { throw QuestionBankError.sessionItemNotFound }
                guard itemRow["answered_at"] == .null || itemRow["answered_at"] == nil else {
                    throw QuestionBankError.itemAlreadyAnswered
                }
                guard itemRow["position"]?.int == sessionRow["current_index"]?.int else {
                    throw QuestionBankError.itemIsNotCurrent
                }

                let payload = try decode(SessionPayload.self, from: itemRow["question_snapshot_json"]?.string ?? "")
                let allowedIDs = Set(payload.options.map(\.id))
                guard !request.selectedOptionIDs.isEmpty, request.selectedOptionIDs.isSubset(of: allowedIDs) else {
                    throw QuestionBankError.invalidSelection
                }
                let correctIDs = Set(try decodeStringArray(itemRow["correct_option_ids_json"]?.string))
                let isCorrect = request.selectedOptionIDs == correctIDs
                let effectiveWrong = !isCorrect || request.markAsUnsure
                let questionID = itemRow["question_id"]?.string ?? ""
                let state = try stateRow(questionID: questionID)
                let wasWrong = state?["is_wrong_book"]?.int == 1
                let progressBefore = state?["consecutive_correct"]?.int ?? 0
                let required = try readSettings().wrongRequiredConsecutiveCorrect
                var isWrong = wasWrong
                var progressAfter = progressBefore
                var removed = false
                if effectiveWrong {
                    isWrong = true
                    progressAfter = 0
                } else if wasWrong {
                    progressAfter += 1
                    if progressAfter >= required {
                        isWrong = false
                        removed = true
                    }
                } else {
                    progressAfter = 0
                }

                let submittedAt = request.submittedAt.timeIntervalSince1970
                try db.execute(
                    """
                    INSERT INTO question_state(question_id, last_answered_at, total_attempts, correct_attempts,
                        wrong_attempts, is_wrong_book, consecutive_correct, added_to_wrong_at, removed_from_wrong_at, updated_at)
                    VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?)
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
                    [
                        .text(questionID), .real(submittedAt), .integer(isCorrect ? 1 : 0),
                        .integer(effectiveWrong ? 1 : 0), .integer(isWrong ? 1 : 0),
                        .integer(Int64(progressAfter)), isWrong ? .real(submittedAt) : .null,
                        removed ? .real(submittedAt) : .null,
                        .real(submittedAt)
                    ]
                )

                let attemptID = UUID().uuidString
                let mode = PracticeMode(rawValue: sessionRow["mode"]?.string ?? "") ?? .normal
                let nextIndex = (sessionRow["current_index"]?.int ?? 0) + 1
                let total = sessionRow["total_items"]?.int ?? 0
                let complete = nextIndex >= total
                try db.execute(
                    """
                    UPDATE practice_sessions SET current_index = ?, status = ?, updated_at = ?, completed_at = ? WHERE id = ?
                    """,
                    [
                        .integer(Int64(nextIndex)), .text(complete ? "completed" : "active"), .real(submittedAt),
                        complete ? .real(submittedAt) : .null, .text(request.sessionID)
                    ]
                )
                let session = try sessionSnapshot(id: request.sessionID)
                let answer = SubmissionResult(
                    attemptID: attemptID,
                    isCorrect: isCorrect,
                    correctOptionIDs: correctIDs,
                    selectedOptionIDs: request.selectedOptionIDs,
                    explanation: payload.explanation,
                    markedAsUnsure: request.markAsUnsure,
                    isInWrongBook: isWrong,
                    wrongProgressBefore: progressBefore,
                    wrongProgressAfter: progressAfter,
                    removedFromWrongBook: removed,
                    session: session
                )
                try db.execute(
                    """
                    INSERT INTO attempts(id, submission_token, session_id, session_item_id, question_id, mode,
                        submitted_at, selected_option_ids_json, displayed_option_order_json, correct_option_ids_json,
                        is_correct, marked_unsure, was_in_wrong_book, is_in_wrong_book, wrong_progress_before,
                        wrong_progress_after, removed_from_wrong_book, explanation_snapshot, result_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(attemptID), .text(request.submissionToken), .text(request.sessionID), .text(request.itemID),
                        .text(questionID), .text(mode.rawValue), .real(submittedAt),
                        .text(try request.selectedOptionIDs.sorted().encodedJSONString()),
                        .text(itemRow["option_order_json"]?.string ?? "[]"),
                        .text(try correctIDs.sorted().encodedJSONString()), .integer(isCorrect ? 1 : 0),
                        .integer(request.markAsUnsure ? 1 : 0), .integer(wasWrong ? 1 : 0),
                        .integer(isWrong ? 1 : 0), .integer(Int64(progressBefore)), .integer(Int64(progressAfter)),
                        .integer(removed ? 1 : 0), .text(payload.explanation), .text(try encode(answer))
                    ]
                )
                try db.execute(
                    "UPDATE session_items SET answered_at = ?, attempt_id = ? WHERE id = ?",
                    [.real(submittedAt), .text(attemptID), .text(request.itemID)]
                )
                try appendChange(entityType: "attempt", entityID: attemptID, action: "submitted", payload: "{\"questionID\":\"\(questionID)\"}")
                try appendChange(entityType: "wrong_book", entityID: questionID, action: isWrong ? "active" : "inactive")
                return (answer, true)
            }
        }
        if outcome.changed { notifyChange() }
        return outcome.result
    }

    public func changes(after sequence: Int64 = 0, limit: Int = 500) throws -> [ChangeLogEntry] {
        try queue.sync {
            try db.rows(
                """
                SELECT sequence, source_app, entity_type, entity_id, action, payload_json, created_at
                FROM change_log WHERE sequence > ? ORDER BY sequence LIMIT ?
                """,
                [.integer(sequence), .integer(Int64(max(1, limit)))]
            ).compactMap { row in
                guard let sequence = row["sequence"]?.int,
                      let source = row["source_app"]?.string,
                      let type = row["entity_type"]?.string,
                      let id = row["entity_id"]?.string,
                      let action = row["action"]?.string,
                      let created = row["created_at"]?.double else { return nil }
                return ChangeLogEntry(
                    sequence: Int64(sequence), sourceApplication: source, entityType: type,
                    entityID: id, action: action, payloadJSON: row["payload_json"]?.string,
                    createdAt: Date(timeIntervalSince1970: created)
                )
            }
        }
    }

    private func validate(_ draft: QuestionDraft) throws {
        guard !draft.stableExternalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuestionBankError.invalidQuestion("stableExternalID 不能为空")
        }
        guard !draft.stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuestionBankError.invalidQuestion("题干不能为空")
        }
        guard draft.options.count >= 2 else { throw QuestionBankError.invalidQuestion("每题至少需要 2 个选项") }
        guard draft.options.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw QuestionBankError.invalidQuestion("选项内容不能为空")
        }
        let correctCount = draft.options.filter(\.isCorrect).count
        guard correctCount > 0 else { throw QuestionBankError.invalidQuestion("至少需要一个正确选项") }
        if draft.type == .singleChoice, correctCount != 1 {
            throw QuestionBankError.invalidQuestion("单选题必须且只能有一个正确选项")
        }
    }

    private func readSettings() throws -> SettingsSnapshot {
        guard let row = try db.rows("SELECT * FROM settings WHERE id = 1").first else {
            throw QuestionBankError.database("设置记录不存在")
        }
        return SettingsSnapshot(
            normalReviewIntervalDays: row["normal_review_interval_days"]?.int ?? 7,
            wrongRequiredConsecutiveCorrect: row["wrong_required_consecutive_correct"]?.int ?? 3,
            questionsPerSession: row["questions_per_session"]?.int
        )
    }

    private func upsertQuestionInsideTransaction(_ draft: QuestionDraft) throws -> QuestionImportResult {
        let now = Date().timeIntervalSince1970
        let existing = try db.rows("SELECT * FROM questions WHERE external_id = ? LIMIT 1", [.text(draft.stableExternalID)]).first
        let questionID = existing?["id"]?.string ?? draft.id ?? UUID().uuidString
        let oldOptions = try db.rows(
            "SELECT id, original_label, text, is_correct, sort_order FROM options WHERE question_id = ? AND active = 1 ORDER BY sort_order",
            [.text(questionID)]
        )
        let sameQuestion = existing?["stem"]?.string == draft.stem &&
            existing?["question_type"]?.string == draft.type.rawValue &&
            existing?["explanation"]?.string == draft.explanation &&
            existing?["source"]?.string == draft.source &&
            existing?["source_image_path"]?.string == draft.sourceImagePath &&
            existing?["source_image_hash"]?.string == draft.sourceImageHash &&
            oldOptions.count == draft.options.count && zip(oldOptions, draft.options.enumerated()).allSatisfy { row, pair in
                let (index, option) = pair
                return row["original_label"]?.string == option.originalLabel && row["text"]?.string == option.text &&
                    row["is_correct"]?.int == (option.isCorrect ? 1 : 0) && row["sort_order"]?.int == index
            }
        let status: QuestionImportStatus = existing == nil ? .inserted : (sameQuestion ? .unchanged : .updated)

        try db.execute(
            """
            INSERT INTO questions(id, external_id, stem, question_type, explanation, source, source_image_path,
                source_image_hash, captured_at, active, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(external_id) DO UPDATE SET stem = excluded.stem, question_type = excluded.question_type,
                explanation = excluded.explanation, source = excluded.source, source_image_path = excluded.source_image_path,
                source_image_hash = excluded.source_image_hash, captured_at = excluded.captured_at, active = 1,
                updated_at = excluded.updated_at
            """,
            [
                .text(questionID), .text(draft.stableExternalID), .text(draft.stem), .text(draft.type.rawValue),
                .text(draft.explanation), draft.source.map(SQLiteValue.text) ?? .null,
                draft.sourceImagePath.map(SQLiteValue.text) ?? .null,
                draft.sourceImageHash.map(SQLiteValue.text) ?? .null,
                draft.capturedAt.map { .real($0.timeIntervalSince1970) } ?? .null, .real(now), .real(now)
            ]
        )
        try db.execute("UPDATE options SET active = 0, updated_at = ? WHERE question_id = ?", [.real(now), .text(questionID)])
        for (index, option) in draft.options.enumerated() {
            let optionID = option.id ?? stableID(prefix: "opt", source: "\(draft.stableExternalID)|\(option.originalLabel ?? "")|\(normalizeText(option.text))")
            try db.execute(
                """
                INSERT INTO options(id, question_id, original_label, text, is_correct, sort_order, active, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET original_label = excluded.original_label, text = excluded.text,
                    is_correct = excluded.is_correct, sort_order = excluded.sort_order, active = 1, updated_at = excluded.updated_at
                """,
                [
                    .text(optionID), .text(questionID), option.originalLabel.map(SQLiteValue.text) ?? .null,
                    .text(option.text), .integer(option.isCorrect ? 1 : 0), .integer(Int64(index)), .real(now), .real(now)
                ]
            )
        }

        try db.execute("DELETE FROM question_knowledge_points WHERE question_id = ?", [.text(questionID)])
        for point in draft.knowledgePoints where !normalizeText(point).isEmpty {
            let normalized = normalizeText(point)
            let pointID = stableID(prefix: "kp", source: normalized)
            try db.execute(
                "INSERT OR IGNORE INTO knowledge_points(id, normalized_name, display_name, created_at) VALUES (?, ?, ?, ?)",
                [.text(pointID), .text(normalized), .text(point), .real(now)]
            )
            try db.execute(
                "INSERT OR IGNORE INTO question_knowledge_points(question_id, knowledge_point_id) VALUES (?, ?)",
                [.text(questionID), .text(pointID)]
            )
        }
        try appendChange(entityType: "question", entityID: questionID, action: status.rawValue)
        return QuestionImportResult(questionID: questionID, status: status, addedToWrongBook: false)
    }

    private func sessionSnapshot(id: String) throws -> PracticeSessionSnapshot {
        guard let row = try db.rows(
            "SELECT id, mode, status, current_index, total_items FROM practice_sessions WHERE id = ?",
            [.text(id)]
        ).first else { throw QuestionBankError.sessionNotFound }
        let mode = PracticeMode(rawValue: row["mode"]?.string ?? "") ?? .normal
        let currentIndex = row["current_index"]?.int ?? 0
        let total = row["total_items"]?.int ?? 0
        let complete = row["status"]?.string == "completed"
        let summary = PracticeSessionSummary(
            id: id, mode: mode, currentIndex: currentIndex, totalCount: total,
            answeredCount: currentIndex, isComplete: complete
        )
        guard !complete, let item = try db.rows(
            """
            SELECT id, question_id, question_snapshot_json FROM session_items
            WHERE session_id = ? AND position = ? LIMIT 1
            """,
            [.text(id), .integer(Int64(currentIndex))]
        ).first else {
            return PracticeSessionSnapshot(summary: summary, currentItem: nil)
        }
        let payload = try decode(SessionPayload.self, from: item["question_snapshot_json"]?.string ?? "")
        let questionID = item["question_id"]?.string ?? ""
        let state = try stateRow(questionID: questionID)
        let required = try readSettings().wrongRequiredConsecutiveCorrect
        let question = PracticeQuestion(
            itemID: item["id"]?.string ?? "", questionID: questionID, stem: payload.stem,
            type: payload.type, options: payload.options, explanation: payload.explanation,
            wrongProgress: state?["consecutive_correct"]?.int ?? 0, wrongRequired: required
        )
        return PracticeSessionSnapshot(summary: summary, currentItem: question)
    }

    private func activeSessionSummary() throws -> PracticeSessionSummary? {
        guard let row = try db.rows(
            """
            SELECT id, mode, current_index, total_items FROM practice_sessions
            WHERE status = 'active' ORDER BY updated_at DESC LIMIT 1
            """
        ).first, let id = row["id"]?.string else { return nil }
        return PracticeSessionSummary(
            id: id,
            mode: PracticeMode(rawValue: row["mode"]?.string ?? "") ?? .normal,
            currentIndex: row["current_index"]?.int ?? 0,
            totalCount: row["total_items"]?.int ?? 0,
            answeredCount: row["current_index"]?.int ?? 0,
            isComplete: false
        )
    }

    private func stateRow(questionID: String) throws -> SQLiteRow? {
        try db.rows("SELECT * FROM question_state WHERE question_id = ?", [.text(questionID)]).first
    }

    private func ensureWrongBook(questionID: String, at date: Date, resetProgress: Bool) throws {
        let timestamp = date.timeIntervalSince1970
        try db.execute(
            """
            INSERT INTO question_state(question_id, is_wrong_book, consecutive_correct, added_to_wrong_at, updated_at)
            VALUES (?, 1, 0, ?, ?)
            ON CONFLICT(question_id) DO UPDATE SET is_wrong_book = 1,
                consecutive_correct = CASE WHEN ? = 1 THEN 0 ELSE question_state.consecutive_correct END,
                added_to_wrong_at = CASE WHEN question_state.is_wrong_book = 0 THEN excluded.added_to_wrong_at ELSE question_state.added_to_wrong_at END,
                updated_at = excluded.updated_at
            """,
            [.text(questionID), .real(timestamp), .real(timestamp), .integer(resetProgress ? 1 : 0)]
        )
    }

    private func appendChange(entityType: String, entityID: String, action: String, payload: String? = nil) throws {
        try db.execute(
            "INSERT INTO change_log(source_app, entity_type, entity_id, action, payload_json, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(sourceApplication), .text(entityType), .text(entityID), .text(action),
                payload.map(SQLiteValue.text) ?? .null, .real(Date().timeIntervalSince1970)
            ]
        )
    }

    private func notifyChange() {
        let userInfo: [AnyHashable: Any] = ["databasePath": databaseURL.path, "sourceApplication": sourceApplication]
        NotificationCenter.default.post(name: QuestionBankPaths.databaseChangedNotification, object: self, userInfo: userInfo)
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            QuestionBankPaths.databaseChangedNotification,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
        #endif
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw QuestionBankError.database("Unable to encode JSON")
        }
        return json
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else { throw QuestionBankError.database("Invalid JSON") }
        return try JSONDecoder().decode(type, from: data)
    }

    private func normalizeLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".、:：()（）[]【】"))
            .uppercased()
    }

    private func normalizeText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private func stableID(prefix: String, source: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(prefix)_\(String(hash, radix: 16))"
    }
}
