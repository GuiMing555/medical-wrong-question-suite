import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: PracticeAppStore
    @StateObject private var databaseChanges = DatabaseChangeObserver()

    var body: some View {
        Group {
            if store.session != nil {
                PracticeView(store: store)
            } else {
                HomeView(store: store)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .task {
            if store.session == nil {
                await store.refreshDashboard()
            }
        }
        .onChange(of: databaseChanges.revision) { _ in
            guard store.session == nil else { return }
            Task { await store.refreshDashboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard store.session == nil else { return }
            Task { await store.refreshDashboard() }
        }
        .alert(item: $store.presentedError) { error in
            Alert(
                title: Text("操作未完成"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}
