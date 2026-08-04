import AppKit

final class SettingsWindowController: NSWindowController {
    var onSave: ((AppSettings) -> Result<String, Error>)?
    var onOrganize: (() -> Void)?

    private let shortcutPopup = NSPopUpButton()
    private let capturePathField = NSTextField()
    private let outputPathField = NSTextField()
    private let dailyCheckbox = NSButton(checkboxWithTitle: "每天 15:00 由本机自动整理", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    convenience init(settings: AppSettings) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "错题每日自动化整理 · 设置"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildInterface()
        apply(settings)
    }

    func apply(_ settings: AppSettings) {
        capturePathField.stringValue = settings.captureFolderPath
        outputPathField.stringValue = settings.outputFolderPath
        dailyCheckbox.state = settings.dailyOrganizeEnabled ? .on : .off
        shortcutPopup.selectItem(at: CaptureShortcut.allCases.firstIndex(of: settings.captureShortcut) ?? 0)
    }

    func showStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "截图与错题本设置")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "所有截图都按需要复习处理。本软件在本机完成截图、OCR 和 Word 整理，不上传题目。")
        intro.textColor = .secondaryLabelColor

        shortcutPopup.addItems(withTitles: CaptureShortcut.allCases.map(\.title))

        let captureRow = folderRow(
            label: "截图保存位置",
            field: capturePathField,
            action: #selector(chooseCaptureFolder)
        )
        let outputRow = folderRow(
            label: "Word 保存位置",
            field: outputPathField,
            action: #selector(chooseOutputFolder)
        )

        let shortcutLabel = NSTextField(labelWithString: "截图快捷键")
        shortcutLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let targetHint = NSTextField(wrappingLabelWithString: "设定目标窗口的快捷键固定为 Control + Option + Shift + 1。右 Shift 只有单独轻点时才截图，不影响组合键。")
        targetHint.textColor = .secondaryLabelColor
        targetHint.font = .systemFont(ofSize: 11)

        let outputsTitle = NSTextField(labelWithString: "整理后生成三份可打印文档")
        outputsTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let outputs = NSTextField(wrappingLabelWithString: "• 医学综合错题本_纯题.docx\n• 医学综合错题本_答案与解析.docx\n• 医学综合错题本_薄弱知识点.docx")
        outputs.textColor = .secondaryLabelColor

        dailyCheckbox.target = self
        dailyCheckbox.action = #selector(dailySettingChanged)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 2

        let saveButton = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let organizeButton = NSButton(title: "立即整理", target: self, action: #selector(organizeNow))
        organizeButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [organizeButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [
            heading, intro,
            sectionSeparator(),
            shortcutLabel, shortcutPopup, targetHint,
            sectionSeparator(),
            captureRow, outputRow,
            sectionSeparator(),
            dailyCheckbox, outputsTitle, outputs,
            statusLabel, buttonRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        shortcutPopup.widthAnchor.constraint(equalToConstant: 330).isActive = true
        captureRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        outputRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        targetHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.setHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
    }

    private func folderRow(label: String, field: NSTextField, action: Selector) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.widthAnchor.constraint(equalToConstant: 105).isActive = true
        field.placeholderString = "请选择文件夹"
        let button = NSButton(title: "选择…", target: self, action: action)
        button.bezelStyle = .rounded
        let row = NSStackView(views: [title, field, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func sectionSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func chooseFolder(for field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: field.stringValue, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        field.stringValue = url.path
    }

    @objc private func chooseCaptureFolder() { chooseFolder(for: capturePathField) }
    @objc private func chooseOutputFolder() { chooseFolder(for: outputPathField) }

    @objc private func dailySettingChanged() {
        if dailyCheckbox.state == .on {
            showStatus("保存后将注册本机每日 15:00 定时任务。")
        }
    }

    @objc private func saveSettings() {
        let shortcut = CaptureShortcut.allCases[safe: shortcutPopup.indexOfSelectedItem] ?? .rightShift
        let settings = AppSettings(
            captureFolderPath: capturePathField.stringValue,
            outputFolderPath: outputPathField.stringValue,
            captureShortcut: shortcut,
            dailyOrganizeEnabled: dailyCheckbox.state == .on
        )
        guard let onSave else { return }
        switch onSave(settings) {
        case .success(let message):
            apply(settings.normalized())
            showStatus(message)
        case .failure(let error):
            showStatus(error.localizedDescription, isError: true)
        }
    }

    @objc private func organizeNow() {
        showStatus("正在识别并生成三份 Word 文档……")
        onOrganize?()
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
