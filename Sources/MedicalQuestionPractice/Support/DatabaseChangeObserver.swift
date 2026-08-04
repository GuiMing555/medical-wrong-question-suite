import Foundation

final class DatabaseChangeObserver: ObservableObject {
    @Published private(set) var revision = 0

    private let notificationName = Notification.Name("com.guiming.medicalquestionbank.databaseChanged")
    private var localObserver: NSObjectProtocol?
    private var distributedObserver: NSObjectProtocol?

    init() {
        localObserver = NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.revision += 1
        }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.revision += 1
        }
    }

    deinit {
        if let localObserver { NotificationCenter.default.removeObserver(localObserver) }
        if let distributedObserver { DistributedNotificationCenter.default().removeObserver(distributedObserver) }
    }
}
