import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: PracticeAppStore
    @State private var settings = PracticeSettings()
    @State private var useAllEligibleQuestions = true
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("普通模式") {
                Stepper(value: $settings.normalReviewIntervalDays, in: 1...365) {
                    LabeledContent("重新出题间隔") {
                        Text("\(settings.normalReviewIntervalDays) 天")
                            .monospacedDigit()
                    }
                }
                Text("题目最后一次作答超过该时间后，会再次进入普通模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("错题模式") {
                Stepper(value: $settings.wrongRequiredConsecutiveCorrect, in: 1...20) {
                    LabeledContent("自动移出所需连续正确次数") {
                        Text("\(settings.wrongRequiredConsecutiveCorrect) 次")
                            .monospacedDigit()
                    }
                }
                Text("错题再次答错时，连续正确次数会重置为 0。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("每轮题数") {
                Toggle("练习全部符合条件的题", isOn: $useAllEligibleQuestions)
                if !useAllEligibleQuestions {
                    Stepper(value: questionLimitBinding, in: 5...500, step: 5) {
                        LabeledContent("每轮上限") {
                            Text("\(settings.questionsPerSession ?? 20) 题")
                                .monospacedDigit()
                        }
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("保存设置") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isLoading || isSaving)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 430)
        .task { await load() }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
    }

    private var questionLimitBinding: Binding<Int> {
        Binding(
            get: { settings.questionsPerSession ?? 20 },
            set: { settings.questionsPerSession = $0 }
        )
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            settings = try await store.loadSettings()
            useAllEligibleQuestions = settings.questionsPerSession == nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if useAllEligibleQuestions {
                settings.questionsPerSession = nil
            } else if settings.questionsPerSession == nil {
                settings.questionsPerSession = 20
            }
            try await store.saveSettings(settings)
            statusMessage = "设置已保存。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
