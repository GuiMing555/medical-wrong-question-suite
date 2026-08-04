import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

private let hotKeySignature: OSType = 0x57514350 // "WQCP"
private let setTargetHotKeyID: UInt32 = 1
private let captureHotKeyID: UInt32 = 2

private struct TargetWindow {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String

    var displayName: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? ownerName : "\(ownerName) — \(trimmedTitle)"
    }
}

private let globalHotKeyHandler: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let controller = Unmanaged<AppController>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.handleHotKey(hotKeyID.id)
    }
    return noErr
}

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var targetDescriptionItem: NSMenuItem!
    private var lastCaptureItem: NSMenuItem!
    private var captureItem: NSMenuItem!
    private var targetWindow: TargetWindow?
    private var setTargetHotKey: EventHotKeyRef?
    private var captureHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var globalEventMonitor: Any?
    private var rightShiftIsDown = false
    private var rightShiftWasUsedAsModifier = false
    private var organizerIsRunning = false
    private var organizerStatusItem: NSMenuItem!
    private var settings = AppSettings.load()
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenuBar()
        registerGlobalHotKeys()
        installRightShiftMonitor()
        requestAccessibilityPermission()
        _ = try? synchronizeLocalSchedule(showErrors: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let setTargetHotKey { UnregisterEventHotKey(setTargetHotKey) }
        if let captureHotKey { UnregisterEventHotKey(captureHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "题"
        statusItem.button?.toolTip = "错题每日自动化整理"

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "错题每日自动化整理", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let settingsItem = NSMenuItem(
            title: "打开设置…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        targetDescriptionItem = NSMenuItem(title: "目标：未设置", action: nil, keyEquivalent: "")
        targetDescriptionItem.isEnabled = false
        menu.addItem(targetDescriptionItem)
        menu.addItem(.separator())

        let setTargetItem = NSMenuItem(
            title: "设定当前前台窗口为目标    ⌃⌥⇧1",
            action: #selector(setCurrentFrontmostWindow),
            keyEquivalent: ""
        )
        setTargetItem.target = self
        menu.addItem(setTargetItem)

        captureItem = NSMenuItem(
            title: "截图目标窗口                 \(settings.captureShortcut.menuTitle)",
            action: #selector(captureTargetWindow),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())

        lastCaptureItem = NSMenuItem(title: "最近截图：暂无", action: nil, keyEquivalent: "")
        lastCaptureItem.isEnabled = false
        menu.addItem(lastCaptureItem)

        let openFolderItem = NSMenuItem(
            title: "打开截图文件夹",
            action: #selector(openCaptureFolder),
            keyEquivalent: ""
        )
        openFolderItem.target = self
        menu.addItem(openFolderItem)
        let organizeItem = NSMenuItem(
            title: "立即整理错题本",
            action: #selector(organizeNow),
            keyEquivalent: ""
        )
        organizeItem.target = self
        menu.addItem(organizeItem)

        let openBooksItem = NSMenuItem(
            title: "打开错题本文件夹",
            action: #selector(openBooksFolder),
            keyEquivalent: ""
        )
        openBooksItem.target = self
        menu.addItem(openBooksItem)

        organizerStatusItem = NSMenuItem(title: scheduleStatusTitle, action: nil, keyEquivalent: "")
        organizerStatusItem.isEnabled = false
        menu.addItem(organizerStatusItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func registerGlobalHotKeys() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        let setStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_1),
            modifiers,
            EventHotKeyID(signature: hotKeySignature, id: setTargetHotKeyID),
            GetApplicationEventTarget(),
            0,
            &setTargetHotKey
        )
        if installStatus != noErr || setStatus != noErr {
            showAlert(
                title: "快捷键注册失败",
                message: "全局快捷键可能与其他应用冲突。请退出占用快捷键的应用后重新启动。"
            )
        }
        registerCaptureHotKey()
    }

    private func registerCaptureHotKey() {
        if let captureHotKey {
            UnregisterEventHotKey(captureHotKey)
            self.captureHotKey = nil
        }
        guard settings.captureShortcut != .rightShift else { return }

        let keyCode: UInt32
        let modifiers: UInt32
        switch settings.captureShortcut {
        case .rightShift:
            return
        case .controlOptionShift2:
            keyCode = UInt32(kVK_ANSI_2)
            modifiers = UInt32(controlKey | optionKey | shiftKey)
        case .controlOptionShiftS:
            keyCode = UInt32(kVK_ANSI_S)
            modifiers = UInt32(controlKey | optionKey | shiftKey)
        case .optionShiftS:
            keyCode = UInt32(kVK_ANSI_S)
            modifiers = UInt32(optionKey | shiftKey)
        }
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: hotKeySignature, id: captureHotKeyID),
            GetApplicationEventTarget(),
            0,
            &captureHotKey
        )
        if status != noErr {
            showAlert(title: "截图快捷键注册失败", message: "该组合键可能已被其他应用占用，请在设置中换一个快捷键。")
        }
    }

    func handleHotKey(_ id: UInt32) {
        switch id {
        case setTargetHotKeyID:
            setCurrentFrontmostWindow()
        case captureHotKeyID:
            captureTargetWindow()
        default:
            break
        }
    }

    private func installRightShiftMonitor() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .flagsChanged,
                .keyDown,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .scrollWheel
            ]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleGlobalEvent(event)
            }
        }
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        guard settings.captureShortcut == .rightShift else { return }
        if event.type == .flagsChanged, event.keyCode == UInt16(kVK_RightShift) {
            if rightShiftIsDown {
                let shouldCapture = !rightShiftWasUsedAsModifier
                rightShiftIsDown = false
                rightShiftWasUsedAsModifier = false
                if shouldCapture {
                    captureTargetWindow()
                }
            } else {
                rightShiftIsDown = true
                rightShiftWasUsedAsModifier = false
            }
            return
        }

        if rightShiftIsDown {
            rightShiftWasUsedAsModifier = true
        }
    }

    private func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        if settings.captureShortcut == .rightShift && !AXIsProcessTrustedWithOptions(options) {
            lastCaptureItem.title = "轻点右⇧需要辅助功能权限，授权后请重启"
        }
    }

    @objc private func setCurrentFrontmostWindow() {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            showAlert(title: "无法识别窗口", message: "没有检测到前台应用。")
            return
        }

        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            showAlert(
                title: "请选择目标窗口",
                message: "先点一下需要截图的题库窗口，再按 Control + Option + Shift + 1。"
            )
            return
        }

        guard let window = largestOnScreenWindow(for: application.processIdentifier) else {
            showAlert(
                title: "未找到可截图窗口",
                message: "请确保目标窗口未最小化，并位于当前桌面。"
            )
            return
        }

        targetWindow = window
        targetDescriptionItem.title = "目标：\(shortened(window.displayName, limit: 42))"
        statusItem.button?.title = "✓"
        NSSound(named: "Tink")?.play()
    }

    @objc private func captureTargetWindow() {
        guard let targetWindow else {
            showAlert(
                title: "尚未指定窗口",
                message: "先让题库窗口位于最前面，然后按 Control + Option + Shift + 1；以后使用“\(settings.captureShortcut.title)”截图。"
            )
            return
        }

        if #available(macOS 10.15, *), !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                showAlert(
                    title: "需要屏幕录制权限",
                    message: "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许本程序，然后重新启动。"
                )
                return
            }
        }

        guard windowStillExists(targetWindow.id) else {
            self.targetWindow = nil
            targetDescriptionItem.title = "目标：窗口已关闭，请重新设置"
            statusItem.button?.title = "!"
            showAlert(title: "目标窗口已关闭", message: "请重新设定当前前台窗口。")
            return
        }

        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            targetWindow.id,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            showAlert(
                title: "截图失败",
                message: "请确认目标窗口未最小化，并检查屏幕录制权限。"
            )
            return
        }

        do {
            let outputURL = try save(image: image, target: targetWindow)
            lastCaptureItem.title = "最近截图：\(outputURL.lastPathComponent)"
            statusItem.button?.title = "✓"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(outputURL.path, forType: .string)
            NSSound(named: "Pop")?.play()
        } catch {
            showAlert(title: "保存失败", message: error.localizedDescription)
        }
    }

    private func largestOnScreenWindow(for pid: pid_t) -> TargetWindow? {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let candidates: [(TargetWindow, CGFloat)] = rawList.compactMap { info in
            guard
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                ownerPID == pid,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                bounds.width >= 240,
                bounds.height >= 160
            else {
                return nil
            }

            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? "未知应用"
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let target = TargetWindow(
                id: CGWindowID(windowNumber),
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title
            )
            return (target, bounds.width * bounds.height)
        }

        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    private func windowStillExists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
        }
    }

    private func save(image: CGImage, target: TargetWindow) throws -> URL {
        let folder = try datedCaptureFolder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"

        let windowLabel = sanitizeFileName(target.title.isEmpty ? target.ownerName : target.title)
        let fileName = "错题_\(formatter.string(from: Date()))_\(windowLabel).png"
        let outputURL = folder.appendingPathComponent(fileName)

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "WrongQuestionCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 图像。"]
            )
        }
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func captureRootFolder() throws -> URL {
        let root = settings.captureFolderURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func datedCaptureFolder() throws -> URL {
        let root = try captureRootFolder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        let folder = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func sanitizeFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened(cleaned.isEmpty ? "窗口" : cleaned, limit: 50)
    }

    private func shortened(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    @objc private func openCaptureFolder() {
        do {
            NSWorkspace.shared.open(try captureRootFolder())
        } catch {
            showAlert(title: "无法打开文件夹", message: error.localizedDescription)
        }
    }

    @objc private func openBooksFolder() {
        do {
            NSWorkspace.shared.open(try WrongQuestionOrganizer.outputFolder(settings: settings))
        } catch {
            showAlert(title: "无法打开错题本文件夹", message: error.localizedDescription)
        }
    }

    @objc private func organizeNow() {
        guard !organizerIsRunning else { return }
        organizerIsRunning = true
        organizerStatusItem.title = "正在识别并整理……"
        statusItem.button?.title = "…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try WrongQuestionOrganizer().run(settings: self?.settings ?? .load())
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.organizerIsRunning = false
                    self.organizerStatusItem.title = self.scheduleStatusTitle
                    self.statusItem.button?.title = "✓"
                    self.settingsWindowController?.showStatus(report.summary)
                    NSSound(named: "Glass")?.play()
                    self.showAlert(title: "错题本已更新", message: report.summary)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.organizerIsRunning = false
                    self.organizerStatusItem.title = "整理失败：请查看提示"
                    self.statusItem.button?.title = "!"
                    self.settingsWindowController?.showStatus(error.localizedDescription, isError: true)
                    self.showAlert(title: "整理失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private var scheduleStatusTitle: String {
        settings.dailyOrganizeEnabled
            ? "本机每日 15:00 自动整理：已启用"
            : "本机每日 15:00 自动整理：已关闭"
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onSave = { [weak self] proposed in
                guard let self else {
                    return .failure(NSError(domain: "Settings", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "应用已退出。"]))
                }
                do {
                    let normalized = proposed.normalized()
                    try normalized.save()
                    self.settings = normalized
                    self.captureItem.title = "截图目标窗口                 \(normalized.captureShortcut.menuTitle)"
                    self.organizerStatusItem.title = self.scheduleStatusTitle
                    self.rightShiftIsDown = false
                    self.rightShiftWasUsedAsModifier = false
                    self.registerCaptureHotKey()
                    self.requestAccessibilityPermission()
                    try self.synchronizeLocalSchedule(showErrors: true)
                    return .success("设置已保存；截图和三份 Word 文档都将写入新位置。")
                } catch {
                    return .failure(error)
                }
            }
            controller.onOrganize = { [weak self] in self?.organizeNow() }
            settingsWindowController = controller
        } else {
            settingsWindowController?.apply(settings)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func synchronizeLocalSchedule(showErrors: Bool) throws -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        do {
            try LocalScheduler.sync(enabled: settings.dailyOrganizeEnabled, executableURL: executable)
            return true
        } catch {
            if showErrors { throw error }
            return false
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.contains("--organize-now") {
    do {
        let report = try WrongQuestionOrganizer().run()
        print(report.summary)
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("整理失败：\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else {
    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.run()
}
