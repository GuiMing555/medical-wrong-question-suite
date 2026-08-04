import Foundation

public enum PracticeMode: String, Codable, Sendable {
    case normal
    case wrongBook = "wrong_book"
}

public enum QuestionType: String, Codable, Sendable {
    case singleChoice = "single_choice"
    case multipleChoice = "multiple_choice"
}

public struct OptionDraft: Equatable, Sendable {
    public var id: String?
    public var originalLabel: String?
    public var text: String
    public var isCorrect: Bool

    public init(id: String? = nil, originalLabel: String? = nil, text: String, isCorrect: Bool) {
        self.id = id
        self.originalLabel = originalLabel
        self.text = text
        self.isCorrect = isCorrect
    }
}

public struct QuestionDraft: Equatable, Sendable {
    public var id: String?
    public var stableExternalID: String
    public var stem: String
    public var type: QuestionType
    public var options: [OptionDraft]
    public var explanation: String
    public var knowledgePoints: [String]
    public var source: String?
    public var sourceImagePath: String?
    public var sourceImageHash: String?
    public var capturedAt: Date?

    public init(
        id: String? = nil,
        stableExternalID: String,
        stem: String,
        type: QuestionType,
        options: [OptionDraft],
        explanation: String = "",
        knowledgePoints: [String] = [],
        source: String? = nil,
        sourceImagePath: String? = nil,
        sourceImageHash: String? = nil,
        capturedAt: Date? = nil
    ) {
        self.id = id
        self.stableExternalID = stableExternalID
        self.stem = stem
        self.type = type
        self.options = options
        self.explanation = explanation
        self.knowledgePoints = knowledgePoints
        self.source = source
        self.sourceImagePath = sourceImagePath
        self.sourceImageHash = sourceImageHash
        self.capturedAt = capturedAt
    }
}

public struct CapturedQuestionOption: Equatable, Sendable {
    public var originalLabel: String
    public var text: String

    public init(originalLabel: String, text: String) {
        self.originalLabel = originalLabel
        self.text = text
    }
}

public struct CapturedQuestionDraft: Equatable, Sendable {
    public var stableExternalID: String
    public var stem: String
    public var options: [CapturedQuestionOption]
    public var correctLabels: Set<String>
    public var explanation: String
    public var knowledgePoints: [String]
    public var sourceImagePath: String
    public var sourceImageHash: String
    public var capturedAt: Date
    public var source: String

    public init(
        stableExternalID: String,
        stem: String,
        options: [CapturedQuestionOption],
        correctLabels: Set<String>,
        explanation: String = "",
        knowledgePoints: [String] = [],
        sourceImagePath: String,
        sourceImageHash: String,
        capturedAt: Date,
        source: String = "capture"
    ) {
        self.stableExternalID = stableExternalID
        self.stem = stem
        self.options = options
        self.correctLabels = Set(correctLabels.map(Self.normalizeLabel))
        self.explanation = explanation
        self.knowledgePoints = knowledgePoints
        self.sourceImagePath = sourceImagePath
        self.sourceImageHash = sourceImageHash
        self.capturedAt = capturedAt
        self.source = source
    }

    public static func labels(from answer: String) -> Set<String> {
        let upper = answer.uppercased()
        let letters = upper.unicodeScalars.compactMap { scalar -> String? in
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            return String(Character(scalar))
        }
        return Set(letters)
    }

    private static func normalizeLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".、:：()（）[]【】"))
            .uppercased()
    }
}

public enum QuestionImportStatus: String, Codable, Sendable {
    case inserted
    case updated
    case unchanged
}

public struct QuestionImportResult: Equatable, Sendable {
    public let questionID: String
    public let status: QuestionImportStatus
    public let addedToWrongBook: Bool

    public init(questionID: String, status: QuestionImportStatus, addedToWrongBook: Bool) {
        self.questionID = questionID
        self.status = status
        self.addedToWrongBook = addedToWrongBook
    }
}

public struct SettingsSnapshot: Equatable, Sendable {
    public var normalReviewIntervalDays: Int
    public var wrongRequiredConsecutiveCorrect: Int
    public var questionsPerSession: Int?

    public init(
        normalReviewIntervalDays: Int = 7,
        wrongRequiredConsecutiveCorrect: Int = 3,
        questionsPerSession: Int? = nil
    ) {
        self.normalReviewIntervalDays = normalReviewIntervalDays
        self.wrongRequiredConsecutiveCorrect = wrongRequiredConsecutiveCorrect
        self.questionsPerSession = questionsPerSession
    }
}

public struct PracticeOption: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let originalLabel: String?
}

public struct PracticeQuestion: Codable, Equatable, Sendable {
    public let itemID: String
    public let questionID: String
    public let stem: String
    public let type: QuestionType
    public let options: [PracticeOption]
    public let explanation: String
    public let wrongProgress: Int
    public let wrongRequired: Int

    public var allowsMultipleSelection: Bool { type == .multipleChoice }
}

public struct PracticeSessionSummary: Codable, Equatable, Sendable {
    public let id: String
    public let mode: PracticeMode
    public let currentIndex: Int
    public let totalCount: Int
    public let answeredCount: Int
    public let isComplete: Bool
}

public struct PracticeSessionSnapshot: Codable, Equatable, Sendable {
    public let summary: PracticeSessionSummary
    public let currentItem: PracticeQuestion?

    public var id: String { summary.id }
    public var mode: PracticeMode { summary.mode }
    public var currentIndex: Int { summary.currentIndex }
    public var totalCount: Int { summary.totalCount }
    public var answeredCount: Int { summary.answeredCount }
    public var isComplete: Bool { summary.isComplete }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public let totalQuestions: Int
    public let unseenCount: Int
    public let dueNormalCount: Int
    public let wrongBookCount: Int
    public let answeredTodayCount: Int
    public let activeSession: PracticeSessionSummary?
}

public struct ChangeLogEntry: Equatable, Sendable {
    public let sequence: Int64
    public let sourceApplication: String
    public let entityType: String
    public let entityID: String
    public let action: String
    public let payloadJSON: String?
    public let createdAt: Date
}

public struct SubmitAnswerRequest: Equatable, Sendable {
    public let sessionID: String
    public let itemID: String
    public let selectedOptionIDs: Set<String>
    public let submissionToken: String
    public let markAsUnsure: Bool
    public let submittedAt: Date

    public init(
        sessionID: String,
        itemID: String,
        selectedOptionIDs: Set<String>,
        submissionToken: String = UUID().uuidString,
        markAsUnsure: Bool = false,
        submittedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.itemID = itemID
        self.selectedOptionIDs = selectedOptionIDs
        self.submissionToken = submissionToken
        self.markAsUnsure = markAsUnsure
        self.submittedAt = submittedAt
    }
}

public struct SubmissionResult: Codable, Equatable, Sendable {
    public let attemptID: String
    public let isCorrect: Bool
    public let correctOptionIDs: Set<String>
    public let selectedOptionIDs: Set<String>
    public let explanation: String
    public let markedAsUnsure: Bool
    public let isInWrongBook: Bool
    public let wrongProgressBefore: Int
    public let wrongProgressAfter: Int
    public let removedFromWrongBook: Bool
    public let session: PracticeSessionSnapshot
}

public enum QuestionBankError: Error, Equatable, LocalizedError {
    case invalidQuestion(String)
    case invalidSettings(String)
    case noEligibleQuestions(PracticeMode)
    case wrongModeLocked(unseenCount: Int, wrongCount: Int)
    case sessionNotFound
    case sessionCompleted
    case sessionItemNotFound
    case itemAlreadyAnswered
    case itemIsNotCurrent
    case invalidSelection
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .invalidQuestion(let message), .invalidSettings(let message), .database(let message): return message
        case .noEligibleQuestions(.wrongBook): return "错题本为空"
        case .noEligibleQuestions(.normal): return "当前没有待练习的题目"
        case .wrongModeLocked(let unseenCount, let wrongCount):
            return "还有 \(unseenCount) 道普通题未完成，当前错题 \(wrongCount) 道；累计至少 5 道错题后可开启错题模式"
        case .sessionNotFound: return "练习记录不存在"
        case .sessionCompleted: return "本轮练习已完成"
        case .sessionItemNotFound: return "本轮中不存在该题"
        case .itemAlreadyAnswered: return "该题已提交"
        case .itemIsNotCurrent: return "只能提交当前题"
        case .invalidSelection: return "所选选项不属于当前题"
        }
    }
}

public enum QuestionBankPaths {
    public static let databaseChangedNotification = Notification.Name("com.guiming.medicalquestionbank.databaseChanged")

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("医学综合练习", isDirectory: true)
            .appendingPathComponent("question-bank.sqlite3", isDirectory: false)
    }
}
