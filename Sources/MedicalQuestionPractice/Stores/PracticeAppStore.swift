import Foundation

@MainActor
final class PracticeAppStore: ObservableObject {
    @Published private(set) var dashboard: DashboardSummary = .empty
    @Published private(set) var session: PracticeSessionState?
    @Published private(set) var feedback: AnswerFeedback?
    @Published private(set) var answeredQuestion: PracticeQuestion?
    @Published private(set) var reviewedAnswer: AnsweredQuestionReview?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published var presentedError: PresentedError?

    private let repository: any PracticeRepository
    private var pendingSubmissionTokens: [String: String] = [:]
    private var answerHistory: [AnsweredQuestionReview] = []
    private var reviewedAnswerIndex: Int?

    init(repository: any PracticeRepository) {
        self.repository = repository
    }

    func refreshDashboard() async {
        isLoading = true
        defer { isLoading = false }
        do {
            dashboard = try await repository.dashboard()
        } catch {
            present(error)
        }
    }

    func start(_ mode: PracticeMode) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            feedback = nil
            answeredQuestion = nil
            reviewedAnswer = nil
            reviewedAnswerIndex = nil
            answerHistory.removeAll()
            session = try await repository.startSession(mode: mode)
            dashboard = try await repository.dashboard()
        } catch {
            present(error)
        }
    }

    func submit(selectedOptionIDs: Set<String>, markAsUnsure: Bool) async {
        guard let session, let question = session.currentQuestion,
              feedback == nil, !isSubmitting else { return }

        let submittedSessionID = session.id
        isSubmitting = true
        answeredQuestion = question
        let token = pendingSubmissionTokens[question.id] ?? UUID().uuidString
        pendingSubmissionTokens[question.id] = token
        defer { isSubmitting = false }
        do {
            let result = try await repository.submit(
                sessionID: session.id,
                itemID: question.id,
                selectedOptionIDs: selectedOptionIDs,
                submissionToken: token,
                markAsUnsure: markAsUnsure
            )
            pendingSubmissionTokens.removeValue(forKey: question.id)
            dashboard = try await repository.dashboard()
            guard self.session?.id == submittedSessionID else { return }
            // The repository has committed the answer before this UI state changes.
            answerHistory.append(
                AnsweredQuestionReview(
                    position: session.currentIndex,
                    question: question,
                    feedback: result
                )
            )
            feedback = result
            self.session = result.session
        } catch {
            guard self.session?.id == submittedSessionID else { return }
            present(error)
        }
    }

    func advanceAfterFeedback() {
        guard let feedback else { return }
        reviewedAnswer = nil
        reviewedAnswerIndex = nil
        self.feedback = nil
        answeredQuestion = nil
        session = feedback.session
    }

    @discardableResult
    func showPreviousQuestion() -> Bool {
        guard !answerHistory.isEmpty else { return false }

        let targetIndex: Int
        if let reviewedAnswerIndex {
            targetIndex = reviewedAnswerIndex - 1
        } else if feedback != nil {
            targetIndex = answerHistory.count - 2
        } else {
            targetIndex = answerHistory.count - 1
        }
        guard answerHistory.indices.contains(targetIndex) else { return false }

        reviewedAnswerIndex = targetIndex
        reviewedAnswer = answerHistory[targetIndex]
        return true
    }

    @discardableResult
    func showNextQuestion() -> Bool {
        guard let reviewedAnswerIndex else {
            if feedback != nil {
                advanceAfterFeedback()
                return true
            }
            return false
        }

        let nextIndex = reviewedAnswerIndex + 1
        if feedback != nil, nextIndex == answerHistory.count - 1 {
            self.reviewedAnswerIndex = nil
            reviewedAnswer = nil
        } else if answerHistory.indices.contains(nextIndex) {
            self.reviewedAnswerIndex = nextIndex
            reviewedAnswer = answerHistory[nextIndex]
        } else {
            self.reviewedAnswerIndex = nil
            reviewedAnswer = nil
        }
        return true
    }

    var canShowPreviousQuestion: Bool {
        if let reviewedAnswerIndex { return reviewedAnswerIndex > 0 }
        if feedback != nil { return answerHistory.count >= 2 }
        return !answerHistory.isEmpty
    }

    var canShowNextQuestion: Bool {
        reviewedAnswerIndex != nil || feedback != nil
    }

    var displayedQuestionNumber: Int {
        if let reviewedAnswer { return reviewedAnswer.position + 1 }
        if feedback != nil, let latest = answerHistory.last { return latest.position + 1 }
        return min((session?.currentIndex ?? 0) + 1, session?.totalCount ?? 1)
    }

    func leavePractice() {
        let sessionID = session?.id
        feedback = nil
        answeredQuestion = nil
        reviewedAnswer = nil
        reviewedAnswerIndex = nil
        answerHistory.removeAll()
        session = nil
        pendingSubmissionTokens.removeAll()
        if let sessionID {
            do {
                try repository.finishSession(id: sessionID)
            } catch {
                present(error)
            }
        }
        Task { await refreshDashboard() }
    }

    func loadSettings() async throws -> PracticeSettings {
        try await repository.loadSettings()
    }

    func saveSettings(_ settings: PracticeSettings) async throws {
        try await repository.saveSettings(settings)
        await refreshDashboard()
    }

    private func present(_ error: Error) {
        presentedError = PresentedError(message: error.localizedDescription)
    }
}

struct PresentedError: Identifiable {
    let id = UUID()
    let message: String
}
