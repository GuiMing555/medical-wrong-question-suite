import XCTest
@testable import QuestionBankCore

final class QuestionBankCoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var databaseURL: URL!
    private var store: QuestionBankStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuestionBankCoreTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = temporaryDirectory.appendingPathComponent("question-bank.sqlite3")
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "tests")
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testNormalModeUsesUnseenThenDueAndDashboardDoesNotDoubleCountUnseen() throws {
        try insertQuestion(number: 1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var dashboard = try store.dashboard(now: now)
        XCTAssertEqual(dashboard.unseenCount, 1)
        XCTAssertEqual(dashboard.dueNormalCount, 0)

        let session = try store.startSession(mode: .normal, now: now, seed: 1)
        _ = try answer(session, correct: true, at: now)
        dashboard = try store.dashboard(now: now.addingTimeInterval(86_400))
        XCTAssertEqual(dashboard.unseenCount, 0)
        XCTAssertEqual(dashboard.dueNormalCount, 0)
        XCTAssertThrowsError(try store.startSession(mode: .normal, now: now.addingTimeInterval(86_400))) { error in
            XCTAssertEqual(error as? QuestionBankError, .noEligibleQuestions(.normal))
        }

        dashboard = try store.dashboard(now: now.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(dashboard.dueNormalCount, 1)
        XCTAssertNoThrow(try store.startSession(mode: .normal, now: now.addingTimeInterval(8 * 86_400), seed: 2))
    }

    func testSessionAndShuffledOptionsResumeAfterStoreRestart() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        let session = try store.startSession(mode: .normal, seed: 99)
        let first = try XCTUnwrap(session.currentItem)
        let firstOrder = first.options.map(\.id)

        store = nil
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "restarted-tests")
        let resumed = try XCTUnwrap(store.currentSession(mode: .normal))
        XCTAssertEqual(resumed.id, session.id)
        XCTAssertEqual(resumed.currentItem?.itemID, first.itemID)
        XCTAssertEqual(resumed.currentItem?.options.map(\.id), firstOrder)

        _ = try answer(resumed, correct: true)
        store = nil
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "restarted-again")
        let progressed = try XCTUnwrap(store.currentSession(mode: .normal))
        XCTAssertEqual(progressed.currentIndex, 1)
        XCTAssertNotEqual(progressed.currentItem?.itemID, first.itemID)
    }

    func testWrongModeUnavailableWhenEmptyAndThresholdRemovesQuestion() throws {
        try insertQuestion(number: 1)
        XCTAssertThrowsError(try store.startSession(mode: .wrongBook)) { error in
            XCTAssertEqual(error as? QuestionBankError, .noEligibleQuestions(.wrongBook))
        }

        let normal = try store.startSession(mode: .normal, seed: 3)
        let wrong = try answer(normal, correct: false)
        XCTAssertTrue(wrong.isInWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 1)

        try store.updateSettings(SettingsSnapshot(normalReviewIntervalDays: 7, wrongRequiredConsecutiveCorrect: 2))
        let correction1 = try store.startSession(mode: .wrongBook, seed: 4)
        let firstCorrect = try answer(correction1, correct: true)
        XCTAssertEqual(firstCorrect.wrongProgressAfter, 1)
        XCTAssertTrue(firstCorrect.isInWrongBook)

        let correction2 = try store.startSession(mode: .wrongBook, seed: 5)
        let secondCorrect = try answer(correction2, correct: true)
        XCTAssertEqual(secondCorrect.wrongProgressAfter, 2)
        XCTAssertTrue(secondCorrect.removedFromWrongBook)
        XCTAssertFalse(secondCorrect.isInWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)
    }

    func testWrongAnswerResetsConsecutiveCorrectProgress() throws {
        try insertQuestion(number: 1)
        try store.updateSettings(SettingsSnapshot(normalReviewIntervalDays: 7, wrongRequiredConsecutiveCorrect: 2))
        let normal = try store.startSession(mode: .normal, seed: 1)
        _ = try answer(normal, correct: false)

        let first = try store.startSession(mode: .wrongBook, seed: 2)
        XCTAssertEqual(try answer(first, correct: true).wrongProgressAfter, 1)

        let second = try store.startSession(mode: .wrongBook, seed: 3)
        let reset = try answer(second, correct: false)
        XCTAssertEqual(reset.wrongProgressBefore, 1)
        XCTAssertEqual(reset.wrongProgressAfter, 0)

        let third = try store.startSession(mode: .wrongBook, seed: 4)
        XCTAssertEqual(try answer(third, correct: true).wrongProgressAfter, 1)
        XCTAssertEqual(try store.wrongBookCount(), 1)
    }

    func testSubmissionTokenIsIdempotent() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        let session = try store.startSession(mode: .normal, seed: 8)
        let item = try XCTUnwrap(session.currentItem)
        let selected = try optionIDs(in: item, correct: false)
        let token = "fixed-submission-token"
        let request = SubmitAnswerRequest(
            sessionID: session.id,
            itemID: item.itemID,
            selectedOptionIDs: selected,
            submissionToken: token
        )
        let first = try store.submit(request)
        let retry = try store.submit(request)
        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.session.currentIndex, 1)
        XCTAssertEqual(try store.dashboard().answeredTodayCount, 1)
    }

    func testCaptureImportDoesNotCreateOrRestoreWrongBookState() throws {
        try store.updateSettings(SettingsSnapshot(normalReviewIntervalDays: 7, wrongRequiredConsecutiveCorrect: 1))
        let first = capturedQuestion(hash: "image-hash-1")
        let inserted = try store.importCapturedQuestion(first)
        XCTAssertEqual(inserted.status, .inserted)
        XCTAssertFalse(inserted.addedToWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)

        let duplicate = try store.importCapturedQuestion(first)
        XCTAssertEqual(duplicate.status, .unchanged)
        XCTAssertFalse(duplicate.addedToWrongBook)

        let normal = try store.startSession(mode: .normal, seed: 8)
        _ = try answer(normal, correct: false)

        let correction = try store.startSession(mode: .wrongBook, seed: 9)
        XCTAssertTrue(try answer(correction, correct: true).removedFromWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)

        let newEvent = try store.importCapturedQuestion(capturedQuestion(hash: "image-hash-2"))
        XCTAssertEqual(newEvent.status, .updated)
        XCTAssertFalse(newEvent.addedToWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)
    }

    func testMigration3ClearsLegacyUnansweredCaptureWrongState() throws {
        let imported = try store.importCapturedQuestion(capturedQuestion(hash: "legacy-capture-hash"))
        store = nil

        var rawDatabase: SQLiteDatabase? = try SQLiteDatabase(url: databaseURL)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970
        try rawDatabase?.execute(
            """
            INSERT INTO question_state(question_id, is_wrong_book, added_to_wrong_at, updated_at)
            VALUES (?, 1, ?, ?)
            """,
            [.text(imported.questionID), .real(timestamp), .real(timestamp)]
        )
        try rawDatabase?.execute(
            """
            INSERT INTO change_log(source_app, entity_type, entity_id, action, created_at)
            VALUES ('capture', 'wrong_book', ?, 'capture_added', ?)
            """,
            [.text(imported.questionID), .real(timestamp)]
        )
        try rawDatabase?.execute("DELETE FROM schema_migrations WHERE version = 3")
        rawDatabase = nil

        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "migration-test")
        XCTAssertEqual(try store.wrongBookCount(), 0)

        store = nil
        rawDatabase = try SQLiteDatabase(url: databaseURL)
        XCTAssertEqual(
            try rawDatabase?.scalarInt("SELECT COUNT(*) FROM schema_migrations WHERE version = 3"),
            1
        )
        XCTAssertEqual(
            try rawDatabase?.scalarInt(
                "SELECT COUNT(*) FROM change_log WHERE action = 'cleared_auto_capture_wrong'"
            ),
            1
        )
        rawDatabase = nil
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "tests")
    }

    func testSameCaptureHashRefreshesCorrectedExplanationWithoutReaddingWrongBook() throws {
        let original = capturedQuestion(hash: "same-image-hash")
        XCTAssertEqual(try store.importCapturedQuestion(original).status, .inserted)

        let corrected = CapturedQuestionDraft(
            stableExternalID: original.stableExternalID,
            stem: original.stem,
            options: original.options,
            correctLabels: original.correctLabels,
            explanation: "修正后的截图解析",
            knowledgePoints: original.knowledgePoints,
            sourceImagePath: original.sourceImagePath,
            sourceImageHash: original.sourceImageHash,
            capturedAt: original.capturedAt
        )
        let refreshed = try store.importCapturedQuestion(corrected)
        XCTAssertEqual(refreshed.status, .updated)
        XCTAssertFalse(refreshed.addedToWrongBook)
        XCTAssertEqual(try store.wrongBookCount(), 0)

        let session = try store.startSession(mode: .normal, seed: 11)
        XCTAssertEqual(session.currentItem?.explanation, "修正后的截图解析")
    }

    func testExplanationBoundaryStopsPageControlsAndOCRVariantsOnly() {
        XCTAssertTrue(ExplanationBoundary.isExactMarker("试题答疑"))
        XCTAssertTrue(ExplanationBoundary.shouldStop(
            at: "放题笔讥",
            previousContentLine: "正常解析。",
            isLastLine: true
        ))
        XCTAssertTrue(ExplanationBoundary.shouldStop(
            at: "口5",
            previousContentLine: "正常解析。",
            isLastLine: true
        ))
        XCTAssertTrue(ExplanationBoundary.shouldStop(
            at: "半旺处堅",
            previousContentLine: "正常解析。",
            isLastLine: true
        ))
        XCTAssertFalse(ExplanationBoundary.shouldStop(
            at: "血压升高",
            previousContentLine: "前一句。",
            isLastLine: true
        ))
    }

    func testQuestionTextCleanupRemovesRepeatedCaseSummary() {
        let duplicated = "女，46岁。进油腻食物后出现阵发性右上腹绞痛，向右肩背部放射1周，症状加重伴发热2小时就诊。1年前 曾诊断为胆石症，未治疗。i 女，46岁。进油腻食物后出现阵发性右上腹绞痛，向右肩背部放射1周，症状加重伴发热2小时就诊。1年前曾诊断为胆石症，未治疗。对该患者诊断最有意义的辅助检查是（）"
        let expected = "女，46岁。进油腻食物后出现阵发性右上腹绞痛，向右肩背部放射1周，症状加重伴发热2小时就诊。1年前曾诊断为胆石症，未治疗。对该患者诊断最有意义的辅助检查是（）"

        XCTAssertEqual(
            QuestionTextCleanup.removingRepeatedIntroductoryBlock(from: duplicated),
            expected
        )
    }

    func testWrongModeRequiresFiveWrongQuestionsWhileNormalQuestionsRemain() throws {
        for number in 1...6 { try insertQuestion(number: number) }

        for index in 1...4 {
            let normal = try store.startSession(mode: .normal, limit: 1, seed: UInt64(index))
            _ = try answer(normal, correct: false)
        }
        XCTAssertEqual(try store.dashboard().wrongBookCount, 4)
        XCTAssertThrowsError(try store.startSession(mode: .wrongBook, seed: 20)) { error in
            XCTAssertEqual(
                error as? QuestionBankError,
                .wrongModeLocked(unseenCount: 2, wrongCount: 4)
            )
        }

        let fifth = try store.startSession(mode: .normal, limit: 1, seed: 21)
        _ = try answer(fifth, correct: false)
        XCTAssertEqual(try store.dashboard().wrongBookCount, 5)
        XCTAssertNoThrow(try store.startSession(mode: .wrongBook, seed: 22))
    }

    func testWrongModeAllowsFewerThanFiveAfterAllNormalQuestionsAnswered() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        var normal = try store.startSession(mode: .normal, seed: 30)
        let first = try answer(normal, correct: false)
        normal = first.session
        _ = try answer(normal, correct: true)

        let dashboard = try store.dashboard()
        XCTAssertEqual(dashboard.unseenCount, 0)
        XCTAssertEqual(dashboard.wrongBookCount, 1)
        XCTAssertNoThrow(try store.startSession(mode: .wrongBook, seed: 31))
    }

    func testUnknownAnswerEntersWrongBookAndReturnsCorrectAnswer() throws {
        try insertQuestion(number: 1)
        let session = try store.startSession(mode: .normal, seed: 7)
        let item = try XCTUnwrap(session.currentItem)
        let correctOption = try XCTUnwrap(item.options.first { $0.originalLabel == "B" })
        let result = try store.submit(
            SubmitAnswerRequest(
                sessionID: session.id,
                itemID: item.itemID,
                selectedOptionIDs: [],
                markAsUnsure: true
            )
        )
        XCTAssertFalse(result.isCorrect)
        XCTAssertTrue(result.markedAsUnsure)
        XCTAssertTrue(result.isInWrongBook)
        XCTAssertEqual(result.wrongProgressAfter, 0)
        XCTAssertEqual(result.correctOptionIDs, [correctOption.id])
        XCTAssertEqual(result.explanation, "解析 1")
    }

    func testFinishingSessionLeavesUnansweredQuestionsEligible() throws {
        try insertQuestion(number: 1)
        try insertQuestion(number: 2)
        let session = try store.startSession(mode: .normal, seed: 40)

        try store.finishSession(id: session.id)

        XCTAssertNil(try store.currentSession())
        XCTAssertTrue(try store.session(id: session.id).isComplete)
        XCTAssertEqual(try store.dashboard().unseenCount, 2)

        let next = try store.startSession(mode: .normal, seed: 41, resumeExisting: false)
        XCTAssertNotEqual(next.id, session.id)
        XCTAssertEqual(next.currentIndex, 0)
    }

    func testFinishingActiveSessionsClearsOrphanedRound() throws {
        try insertQuestion(number: 1)
        let session = try store.startSession(mode: .normal, seed: 42)

        try store.finishActiveSessions()

        XCTAssertNil(try store.currentSession())
        XCTAssertTrue(try store.session(id: session.id).isComplete)
    }

    func testTwoApplicationsCanRaceToMigrateTheSameNewDatabase() throws {
        store = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
        var errors: [Error] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 6) { index in
            do {
                let opened = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "app-\(index)")
                _ = try opened.settings()
            } catch {
                lock.lock()
                errors.append(error)
                lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "Concurrent migration errors: \(errors)")
        store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "tests")
    }

    private func insertQuestion(number: Int) throws {
        _ = try store.upsertQuestion(
            QuestionDraft(
                stableExternalID: "question-\(number)",
                stem: "测试题 \(number)",
                type: .singleChoice,
                options: [
                    OptionDraft(originalLabel: "A", text: "错误选项 \(number)", isCorrect: false),
                    OptionDraft(originalLabel: "B", text: "正确选项 \(number)", isCorrect: true),
                    OptionDraft(originalLabel: "C", text: "干扰选项 \(number)", isCorrect: false)
                ],
                explanation: "解析 \(number)",
                knowledgePoints: ["知识点 \(number)"]
            )
        )
    }

    private func capturedQuestion(hash: String) -> CapturedQuestionDraft {
        CapturedQuestionDraft(
            stableExternalID: "captured-question",
            stem: "截图题干",
            options: [
                CapturedQuestionOption(originalLabel: "A", text: "错误"),
                CapturedQuestionOption(originalLabel: "B", text: "正确")
            ],
            correctLabels: ["B"],
            explanation: "截图解析",
            knowledgePoints: ["截图知识点"],
            sourceImagePath: "/tmp/\(hash).png",
            sourceImageHash: hash,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func answer(
        _ session: PracticeSessionSnapshot,
        correct: Bool,
        markUnsure: Bool = false,
        at date: Date = Date()
    ) throws -> SubmissionResult {
        let item = try XCTUnwrap(session.currentItem)
        return try store.submit(
            SubmitAnswerRequest(
                sessionID: session.id,
                itemID: item.itemID,
                selectedOptionIDs: try optionIDs(in: item, correct: correct),
                markAsUnsure: markUnsure,
                submittedAt: date
            )
        )
    }

    private func optionIDs(in item: PracticeQuestion, correct: Bool) throws -> Set<String> {
        let wantedLabel = correct ? "B" : "A"
        let option = try XCTUnwrap(item.options.first { $0.originalLabel == wantedLabel })
        return [option.id]
    }
}
