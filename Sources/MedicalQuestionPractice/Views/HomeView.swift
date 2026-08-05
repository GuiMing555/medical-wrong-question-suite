import SwiftUI

struct HomeView: View {
    @ObservedObject var store: PracticeAppStore

    private var canStartWrongBook: Bool {
        let dashboard = store.dashboard
        return dashboard.wrongBookQuestions > 0
            && (dashboard.wrongBookQuestions >= 5 || dashboard.unseenQuestions == 0)
    }

    private var wrongBookCountText: String {
        let dashboard = store.dashboard
        if dashboard.wrongBookQuestions == 0 { return "暂无错题" }
        if dashboard.unseenQuestions > 0, dashboard.wrongBookQuestions < 5 {
            return "\(dashboard.wrongBookQuestions) 道错题；满 5 道或刷完普通题后开启"
        }
        return "\(dashboard.wrongBookQuestions) 道待掌握"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                modeSection
                statisticsSection
            }
            .padding(32)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await store.refreshDashboard() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isLoading)

                Button {
                    SettingsOpener.open()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .overlay {
            if store.isLoading {
                ProgressView("正在读取题库…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("医学题库练习")
                .font(.largeTitle.weight(.semibold))
            Text("每道题提交后立即保存，退出当前练习时自动交卷。")
                .foregroundStyle(.secondary)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择练习模式")
                .font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 16) {
                PracticeModeCard(
                    mode: .normal,
                    detail: "练习未做过的题，以及已经到复习时间的题。",
                    countText: "\(store.dashboard.unseenQuestions + store.dashboard.dueQuestions) 道可练习",
                    isEnabled: store.dashboard.unseenQuestions + store.dashboard.dueQuestions > 0
                ) {
                    Task { await store.start(.normal) }
                }

                PracticeModeCard(
                    mode: .wrongBook,
                    detail: "只练习错题，连续做对指定次数后自动移出。未刷完普通题时需先累计 5 道错题。",
                    countText: wrongBookCountText,
                    isEnabled: canStartWrongBook
                ) {
                    Task { await store.start(.wrongBook) }
                }
            }
        }
    }

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("练习概况")
                .font(.title2.weight(.semibold))

            HStack(spacing: 12) {
                StatTile(title: "题库总数", value: store.dashboard.totalQuestions, icon: "books.vertical")
                StatTile(title: "未做过", value: store.dashboard.unseenQuestions, icon: "sparkles")
                StatTile(title: "已到复习时间", value: store.dashboard.dueQuestions, icon: "clock.arrow.circlepath")
                StatTile(title: "当前错题", value: store.dashboard.wrongBookQuestions, icon: "exclamationmark.circle")
                StatTile(title: "今日已答", value: store.dashboard.answeredToday, icon: "checkmark.circle")
            }
        }
    }
}

private struct PracticeModeCard: View {
    let mode: PracticeMode
    let detail: String
    let countText: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

            Text(mode.title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(countText)
                .font(.callout.weight(.medium))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)

            Spacer(minLength: 4)
            Button("开始\(mode.title)", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isEnabled)
                .accessibilityHint(isEnabled ? "" : "当前没有可练习的题目")
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: Int
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.title.weight(.semibold).monospacedDigit())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
