import Foundation
import QuestionBankCore

final class QuestionBankPracticeRepository: PracticeRepository, @unchecked Sendable {
    private let store: QuestionBankStore

    init(databaseURL: URL? = nil) throws {
        if let databaseURL {
            store = try QuestionBankStore(
                databaseURL: databaseURL,
                sourceApplication: "medical-question-practice-macos"
            )
        } else {
            store = try QuestionBankStore(sourceApplication: "medical-question-practice-macos")
        }
    }

    func dashboard() async throws -> DashboardSummary {
        let value = try store.dashboard()
        return DashboardSummary(
            totalQuestions: value.totalQuestions,
            unseenQuestions: value.unseenCount,
            dueQuestions: value.dueNormalCount,
            wrongBookQuestions: value.wrongBookCount,
            answeredToday: value.answeredTodayCount
        )
    }

    func loadSettings() async throws -> PracticeSettings {
        let value = try store.settings()
        return PracticeSettings(
            normalReviewIntervalDays: value.normalReviewIntervalDays,
            wrongRequiredConsecutiveCorrect: value.wrongRequiredConsecutiveCorrect,
            questionsPerSession: value.questionsPerSession
        )
    }

    func saveSettings(_ settings: PracticeSettings) async throws {
        try store.updateSettings(
            SettingsSnapshot(
                normalReviewIntervalDays: settings.normalReviewIntervalDays,
                wrongRequiredConsecutiveCorrect: settings.wrongRequiredConsecutiveCorrect,
                questionsPerSession: settings.questionsPerSession
            )
        )
    }

    func startSession(mode: PracticeMode) async throws -> PracticeSessionState {
        do {
            try store.finishActiveSessions()
            let value = try store.startSession(mode: mapMode(mode), resumeExisting: false)
            return mapSession(value)
        } catch QuestionBankError.wrongModeLocked(let unseenCount, let wrongCount) {
            throw PracticeRepositoryError.wrongModeLocked(
                unseenCount: unseenCount,
                wrongCount: wrongCount
            )
        } catch QuestionBankError.noEligibleQuestions {
            throw PracticeRepositoryError.noEligibleQuestions(mode)
        }
    }

    func finishSession(id: String) throws {
        try store.finishSession(id: id)
    }

    func submit(
        sessionID: String,
        itemID: String,
        selectedOptionIDs: Set<String>,
        submissionToken: String,
        markAsUnsure: Bool
    ) async throws -> AnswerFeedback {
        let value = try store.submit(
            SubmitAnswerRequest(
                sessionID: sessionID,
                itemID: itemID,
                selectedOptionIDs: selectedOptionIDs,
                submissionToken: submissionToken,
                markAsUnsure: markAsUnsure
            )
        )
        let session = mapSession(value.session)
        let progress = value.isInWrongBook
            ? WrongBookProgress(
                consecutiveCorrect: value.wrongProgressAfter,
                requiredCorrect: try store.settings().wrongRequiredConsecutiveCorrect
            )
            : nil
        return AnswerFeedback(
            isCorrect: value.isCorrect,
            selectedOptionIDs: value.selectedOptionIDs,
            correctOptionIDs: value.correctOptionIDs,
            explanation: value.explanation,
            isInWrongBook: value.isInWrongBook,
            wrongBookProgress: progress,
            removedFromWrongBook: value.removedFromWrongBook,
            session: session
        )
    }

    private func mapMode(_ mode: PracticeMode) -> QuestionBankCore.PracticeMode {
        switch mode {
        case .normal: return .normal
        case .wrongBook: return .wrongBook
        }
    }

    private func mapMode(_ mode: QuestionBankCore.PracticeMode) -> PracticeMode {
        switch mode {
        case .normal: return .normal
        case .wrongBook: return .wrongBook
        }
    }

    private func mapSession(_ value: PracticeSessionSnapshot) -> PracticeSessionState {
        let mode = mapMode(value.mode)
        return PracticeSessionState(
            id: value.id,
            mode: mode,
            currentIndex: value.currentIndex,
            totalCount: value.totalCount,
            currentQuestion: value.currentItem.map { mapQuestion($0, mode: mode) },
            isComplete: value.isComplete
        )
    }

    private func mapQuestion(
        _ value: QuestionBankCore.PracticeQuestion,
        mode: PracticeMode
    ) -> PracticeQuestion {
        PracticeQuestion(
            id: value.itemID,
            questionID: value.questionID,
            stem: value.stem,
            options: value.options.map {
                PracticeOption(id: $0.id, text: $0.text, originalLabel: $0.originalLabel)
            },
            allowsMultipleSelection: value.allowsMultipleSelection,
            wrongBookProgress: mode == .wrongBook
                ? WrongBookProgress(
                    consecutiveCorrect: value.wrongProgress,
                    requiredCorrect: value.wrongRequired
                )
                : nil
        )
    }
}

enum PracticeRepositoryFactory {
    static func makeDefault() -> any PracticeRepository {
        do {
            return try QuestionBankPracticeRepository()
        } catch {
            return UnavailablePracticeRepository(message: "无法打开本地题库：\(error.localizedDescription)")
        }
    }
}

private struct UnavailablePracticeRepository: PracticeRepository {
    let message: String

    func dashboard() async throws -> DashboardSummary { throw unavailable }
    func loadSettings() async throws -> PracticeSettings { throw unavailable }
    func saveSettings(_ settings: PracticeSettings) async throws { throw unavailable }
    func startSession(mode: PracticeMode) async throws -> PracticeSessionState { throw unavailable }
    func finishSession(id: String) throws { throw unavailable }
    func submit(
        sessionID: String,
        itemID: String,
        selectedOptionIDs: Set<String>,
        submissionToken: String,
        markAsUnsure: Bool
    ) async throws -> AnswerFeedback { throw unavailable }

    private var unavailable: PracticeRepositoryError { .unavailable(message) }
}
