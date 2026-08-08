import Foundation

enum CaptureShortcut: String, CaseIterable {
    case rightShift
    case controlOptionShift2
    case controlOptionShiftS
    case optionShiftS

    var title: String {
        switch self {
        case .rightShift: return "单独轻点右 Shift（推荐）"
        case .controlOptionShift2: return "Control + Option + Shift + 2"
        case .controlOptionShiftS: return "Control + Option + Shift + S"
        case .optionShiftS: return "Option + Shift + S"
        }
    }

    var menuTitle: String {
        switch self {
        case .rightShift: return "轻点右⇧"
        case .controlOptionShift2: return "⌃⌥⇧2"
        case .controlOptionShiftS: return "⌃⌥⇧S"
        case .optionShiftS: return "⌥⇧S"
        }
    }
}

enum RecognitionMode: String, CaseIterable {
    case fentiQuestionBank
    case general

    var title: String {
        switch self {
        case .fentiQuestionBank: return "焚题库专项优化（推荐）"
        case .general: return "通用识别"
        }
    }

    var detail: String {
        switch self {
        case .fentiQuestionBank:
            return "按焚题库页面区域识别，并清除导航、答题卡、异常选项前缀及重复题干。"
        case .general:
            return "保留更完整的窗口区域，只使用通用题干、选项和答案解析规则。"
        }
    }
}

struct AppSettings {
    private enum Key {
        static let captureFolderPath = "captureFolderPath"
        static let outputFolderPath = "outputFolderPath"
        static let captureShortcut = "captureShortcut"
        static let recognitionMode = "recognitionMode"
        static let dailyOrganizeEnabled = "dailyOrganizeEnabled"
        static let initialized = "settingsInitializedV3"
    }

    var captureFolderPath: String
    var outputFolderPath: String
    var captureShortcut: CaptureShortcut
    var recognitionMode: RecognitionMode
    var dailyOrganizeEnabled: Bool

    static var defaults: AppSettings {
        let capture = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Pictures/错题截图", isDirectory: true)
            .standardizedFileURL.path
        return AppSettings(
            captureFolderPath: capture,
            outputFolderPath: URL(fileURLWithPath: capture)
                .appendingPathComponent("错题本", isDirectory: true).path,
            captureShortcut: .rightShift,
            recognitionMode: .fentiQuestionBank,
            dailyOrganizeEnabled: true
        )
    }

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Key.initialized) else { return .defaults }
        let fallback = AppSettings.defaults
        return AppSettings(
            captureFolderPath: defaults.string(forKey: Key.captureFolderPath) ?? fallback.captureFolderPath,
            outputFolderPath: defaults.string(forKey: Key.outputFolderPath) ?? fallback.outputFolderPath,
            captureShortcut: CaptureShortcut(rawValue: defaults.string(forKey: Key.captureShortcut) ?? "") ?? .rightShift,
            recognitionMode: RecognitionMode(rawValue: defaults.string(forKey: Key.recognitionMode) ?? "") ?? .fentiQuestionBank,
            dailyOrganizeEnabled: defaults.object(forKey: Key.dailyOrganizeEnabled) as? Bool ?? true
        ).normalized()
    }

    func save() throws {
        let value = normalized()
        try value.ensureFoldersExist()
        let defaults = UserDefaults.standard
        defaults.set(value.captureFolderPath, forKey: Key.captureFolderPath)
        defaults.set(value.outputFolderPath, forKey: Key.outputFolderPath)
        defaults.set(value.captureShortcut.rawValue, forKey: Key.captureShortcut)
        defaults.set(value.recognitionMode.rawValue, forKey: Key.recognitionMode)
        defaults.set(value.dailyOrganizeEnabled, forKey: Key.dailyOrganizeEnabled)
        defaults.set(true, forKey: Key.initialized)
    }

    func normalized() -> AppSettings {
        var value = self
        value.captureFolderPath = Self.normalizePath(captureFolderPath)
        value.outputFolderPath = Self.normalizePath(outputFolderPath)
        return value
    }

    func ensureFoldersExist() throws {
        guard !captureFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !outputFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "AppSettings", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "截图和文档保存位置不能为空。"])
        }
        try FileManager.default.createDirectory(at: captureFolderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputFolderURL, withIntermediateDirectories: true)
    }

    var captureFolderURL: URL { URL(fileURLWithPath: captureFolderPath, isDirectory: true).standardizedFileURL }
    var outputFolderURL: URL { URL(fileURLWithPath: outputFolderPath, isDirectory: true).standardizedFileURL }

    private static func normalizePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }
}
