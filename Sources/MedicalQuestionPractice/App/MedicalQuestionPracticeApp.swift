import SwiftUI

@main
struct MedicalQuestionPracticeApp: App {
    @StateObject private var store = PracticeAppStore(repository: PracticeRepositoryFactory.makeDefault())

    var body: some Scene {
        WindowGroup("医学题库练习") {
            ContentView(store: store)
        }
        .defaultSize(width: 980, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("开始普通模式") {
                    Task { await store.start(.normal) }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(
                    store.session != nil || store.dashboard.activeSession != nil
                        || store.dashboard.unseenQuestions + store.dashboard.dueQuestions == 0
                )

                Button("开始错题模式") {
                    Task { await store.start(.wrongBook) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(
                    store.session != nil || store.dashboard.activeSession != nil
                        || store.dashboard.wrongBookQuestions == 0
                )
            }
        }

        Settings {
            SettingsView(store: store)
        }
    }
}
