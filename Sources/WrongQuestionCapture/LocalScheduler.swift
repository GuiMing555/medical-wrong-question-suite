import Foundation
import Darwin

enum LocalScheduler {
    static let label = "com.guiming.wrong-question-daily-organizer.daily"

    static var launchAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func sync(enabled: Bool, executableURL: URL) throws {
        if !enabled {
            try unloadIfPresent()
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            return
        }

        guard executableURL.path.hasPrefix("/Applications/") else {
            throw NSError(domain: "LocalScheduler", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先把应用安装到“应用程序”文件夹，再启用每日整理。"])
        }

        let logs = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/错题每日自动化整理", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path, "--organize-now"],
            "StartCalendarInterval": ["Hour": 15, "Minute": 0],
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("organizer.log").path,
            "StandardErrorPath": logs.appendingPathComponent("organizer-error.log").path
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        try unloadIfPresent()
        try data.write(to: launchAgentURL, options: .atomic)
        try runLaunchctl(["bootstrap", domain, launchAgentURL.path], tolerateMissing: false)
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private static var domain: String { "gui/\(getuid())" }

    private static func unloadIfPresent() throws {
        try runLaunchctl(["bootout", "\(domain)/\(label)"], tolerateMissing: true)
    }

    private static func runLaunchctl(_ arguments: [String], tolerateMissing: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || tolerateMissing else {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "LocalScheduler", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "设置每日 15:00 自动整理失败：\(error)"])
        }
    }
}
