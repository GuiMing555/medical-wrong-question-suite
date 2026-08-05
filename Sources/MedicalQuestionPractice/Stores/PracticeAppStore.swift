import Foundation

@MainActor
final class PracticeAppStore: ObservableObject {
    @Published private(set) var dashboard: DashboardSummary = .empty
    @Published private(set) var session: PracticeSessionState?
    @Published private(set) var feedback: AnswerFeedback?
    @Published private(set) var answeredQuestion: PracticeQuestion?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published var presentedError: PresentedError?

    private let repository: any PracticeRepository
    private var pendingSubmissionTokens: [String: String] = [:]

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
            feedback = result
            self.session = result.session
        } catch {
            guard self.session?.id == submittedSessionID else { return }
            present(error)
        }
    }

    func advanceAfterFeedback() {
        guard let feedback else { return }
        self.feedback = nil
        answeredQuestion = nil
        session = feedback.session
    }

    func leavePractice() {
        let sessionID = session?.id
        feedback = nil
        answeredQuestion = nil
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
