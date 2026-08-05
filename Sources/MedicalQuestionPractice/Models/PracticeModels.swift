import Foundation

enum PracticeMode: String, Codable, Sendable {
    case normal
    case wrongBook

    var title: String {
        switch self {
        case .normal: return "普通模式"
        case .wrongBook: return "错题模式"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "rectangle.stack.badge.play"
        case .wrongBook: return "exclamationmark.arrow.triangle.2.circlepath"
        }
    }
}

struct PracticeSettings: Equatable, Sendable {
    var normalReviewIntervalDays: Int = 7
    var wrongRequiredConsecutiveCorrect: Int = 3
    /// `nil` means that every currently eligible question is included.
    var questionsPerSession: Int? = nil
}

struct DashboardSummary: Equatable, Sendable {
    var totalQuestions: Int
    var unseenQuestions: Int
    var dueQuestions: Int
    var wrongBookQuestions: Int
    var answeredToday: Int

    static let empty = DashboardSummary(
        totalQuestions: 0,
        unseenQuestions: 0,
        dueQuestions: 0,
        wrongBookQuestions: 0,
        answeredToday: 0
    )
}

struct PracticeOption: Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    /// Label in the imported source, used only to update letter references in explanations.
    var originalLabel: String?
}

struct WrongBookProgress: Equatable, Sendable {
    var consecutiveCorrect: Int
    var requiredCorrect: Int

    var remaining: Int { max(0, requiredCorrect - consecutiveCorrect) }
}

struct PracticeQuestion: Identifiable, Equatable, Sendable {
    /// Identifies this question occurrence inside the persisted session.
    var id: String
    var questionID: String
    var stem: String
    var options: [PracticeOption]
    var allowsMultipleSelection: Bool
    var wrongBookProgress: WrongBookProgress?
}

struct PracticeSessionState: Identifiable, Equatable, Sendable {
    var id: String
    var mode: PracticeMode
    var currentIndex: Int
    var totalCount: Int
    var currentQuestion: PracticeQuestion?
    var isComplete: Bool

    var answeredCount: Int { min(currentIndex, totalCount) }
}

struct AnswerFeedback: Equatable, Sendable {
    var isCorrect: Bool
    var selectedOptionIDs: Set<String>
    var correctOptionIDs: Set<String>
    var explanation: String?
    var markedAsUnsure: Bool
    var isInWrongBook: Bool
    var wrongBookProgress: WrongBookProgress?
    var removedFromWrongBook: Bool
    var session: PracticeSessionState
}

struct AnsweredQuestionReview: Equatable, Sendable {
    var position: Int
    var question: PracticeQuestion
    var feedback: AnswerFeedback
}

enum PracticeRepositoryError: LocalizedError {
    case noEligibleQuestions(PracticeMode)
    case wrongModeLocked(unseenCount: Int, wrongCount: Int)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .noEligibleQuestions(.normal):
            return "当前没有未做过或已到复习时间的题目。"
        case .noEligibleQuestions(.wrongBook):
            return "错题本为空，暂时不能开始错题模式。"
        case .wrongModeLocked(let unseenCount, let wrongCount):
            return "还有 \(unseenCount) 道普通题未完成，当前错题 \(wrongCount) 道。错题达到 5 道后可提前开启，或先刷完所有未做题。"
        case .unavailable(let message):
            return message
        }
    }
}
