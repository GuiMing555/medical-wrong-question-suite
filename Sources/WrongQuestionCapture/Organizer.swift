import AppKit
import CryptoKit
import Foundation
import ImageIO
import NaturalLanguage
import QuestionBankCore
import Vision

struct OrganizerReport {
    let newCount: Int
    let updatedCount: Int
    let totalCount: Int
    let uniqueCount: Int
    let duplicateCount: Int
    let repeatedQuestionCount: Int
    let ignoredConsecutiveCount: Int
    let reviewCount: Int
    let repeatedKnowledgeCount: Int
    let questionBankSync: QuestionBankSyncReport
    let questionBook: URL
    let answerBook: URL
    let knowledgeBook: URL

    var summary: String {
        "新增 \(newCount) 张，更新 \(updatedCount) 张，共 \(totalCount) 张截图；" +
        "查重后 \(uniqueCount) 题，合并 \(duplicateCount) 个重复记录，" +
        "\(repeatedQuestionCount) 组题目非连续重复出现，" +
        "忽略 \(ignoredConsecutiveCount) 个连续误操作；" +
        "\(reviewCount) 题需人工校对；\(repeatedKnowledgeCount) 个知识点重复出现。\n" +
        "已生成纯题、答案与解析、薄弱知识点三份文档。\n" +
        questionBankSync.summary + "\n" +
        "文件夹：\(questionBook.deletingLastPathComponent().path)"
    }
}

private struct OrganizerState: Codable {
    var schemaVersion = 8
    var lastRunAt: Date?
    var items: [WrongQuestionItem] = []
}

private struct WrongQuestionItem: Codable {
    var id: String
    var sourcePath: String
    var sourceHash: String
    var capturedAt: Date
    var recognizedAt: Date
    var rawText: String
    var question: String
    var options: [String]
    var correctAnswer: String
    var userAnswer: String
    var explanation: String
    var knowledgePoints: [String]
    var needsReview: Bool
}

private struct ParsedQuestion {
    var question: String
    var options: [String]
    var correctAnswer: String
    var userAnswer: String
    var explanation: String
    var knowledgePoints: [String]
    var needsReview: Bool
}

private struct DeduplicationResult {
    var items: [WrongQuestionItem]
    var episodeItems: [WrongQuestionItem]
    var consecutiveDuplicateItems: [WrongQuestionItem]
    var occurrenceCountsByID: [String: Int]
    var duplicateCount: Int
    var ignoredConsecutiveCount: Int

    var repeatedQuestionCount: Int {
        occurrenceCountsByID.values.filter { $0 >= 2 }.count
    }
}

final class WrongQuestionOrganizer {
    private let fileManager = FileManager.default
    private let stateEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let stateDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func captureRoot(settings: AppSettings = .load()) throws -> URL {
        let root = settings.captureFolderURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func outputFolder(settings: AppSettings = .load()) throws -> URL {
        let folder = settings.outputFolderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func run(settings: AppSettings = .load()) throws -> OrganizerReport {
        try settings.ensureFoldersExist()
        let root = try Self.captureRoot(settings: settings)
        let output = try Self.outputFolder(settings: settings)
        let stateURL = output.appendingPathComponent(".wrong-question-state.json")
        var state = try loadState(from: stateURL)
        var updatedCount = 0
        if state.schemaVersion < 8 {
            for index in state.items.indices {
                let parsed = parse(rawText: state.items[index].rawText, recognitionMode: settings.recognitionMode)
                state.items[index].question = parsed.question
                state.items[index].options = parsed.options
                state.items[index].correctAnswer = parsed.correctAnswer
                state.items[index].userAnswer = parsed.userAnswer
                state.items[index].explanation = parsed.explanation
                state.items[index].knowledgePoints = parsed.knowledgePoints
                state.items[index].needsReview = parsed.needsReview
                state.items[index].recognizedAt = Date()
                updatedCount += 1
            }
            state.schemaVersion = 8
        }
        if settings.recognitionMode == .fentiQuestionBank {
            for index in state.items.indices {
                let normalizedQuestion = normalizedFentiMedicalText(state.items[index].question)
                let normalizedOptions = state.items[index].options.map(normalizedFentiMedicalText)
                let normalizedExplanation = normalizedFentiMedicalText(state.items[index].explanation)
                guard normalizedQuestion != state.items[index].question ||
                        normalizedOptions != state.items[index].options ||
                        normalizedExplanation != state.items[index].explanation
                else { continue }
                state.items[index].question = normalizedQuestion
                state.items[index].options = normalizedOptions
                state.items[index].explanation = normalizedExplanation
                if !normalizedExplanation.hasPrefix("待人工补充") {
                    state.items[index].knowledgePoints = extractKnowledgePoints(
                        from: normalizedExplanation,
                        question: normalizedQuestion
                    )
                }
                state.items[index].recognizedAt = Date()
                updatedCount += 1
            }
        }
        let images = try discoverImages(under: root, excluding: output)
        var itemsByPath = Dictionary(uniqueKeysWithValues: state.items.map { ($0.sourcePath, $0) })
        var nextNumber = (state.items.compactMap { Int($0.id.dropFirst(2)) }.max() ?? 0) + 1
        var newCount = 0

        for (index, imageURL) in images.enumerated() {
            let path = imageURL.path
            let hash = try sha256(of: imageURL)
            if let existing = itemsByPath[path], existing.sourceHash == hash {
                continue
            }

            let rawText = try recognizeText(in: imageURL, recognitionMode: settings.recognitionMode)
            let parsed = parse(rawText: rawText, recognitionMode: settings.recognitionMode)
            let old = itemsByPath[path]
            let item = WrongQuestionItem(
                id: old?.id ?? String(format: "WQ%04d", nextNumber),
                sourcePath: path,
                sourceHash: hash,
                capturedAt: captureDate(for: imageURL),
                recognizedAt: Date(),
                rawText: rawText,
                question: parsed.question,
                options: parsed.options,
                correctAnswer: parsed.correctAnswer,
                userAnswer: parsed.userAnswer,
                explanation: parsed.explanation,
                knowledgePoints: parsed.knowledgePoints,
                needsReview: parsed.needsReview
            )
            itemsByPath[path] = item
            if old == nil {
                newCount += 1
                nextNumber += 1
            } else {
                updatedCount += 1
            }

            let completed = index + 1
            if completed % 10 == 0 || completed == images.count {
                print("OCR 进度：\(completed)/\(images.count)")
                fflush(stdout)
            }
        }

        state.items = itemsByPath.values.sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            return $0.id < $1.id
        }
        state.lastRunAt = Date()

        let deduplicated = deduplicatedItems(state.items)
        let knowledgeCounts = knowledgeOccurrenceCounts(in: deduplicated.episodeItems)
        let questionBook = output.appendingPathComponent("医学综合错题本_纯题.docx")
        let answerBook = output.appendingPathComponent("医学综合错题本_答案与解析.docx")
        let knowledgeBook = output.appendingPathComponent("医学综合错题本_薄弱知识点.docx")
        try createQuestionBook(
            items: deduplicated.items,
            occurrenceCountsByID: deduplicated.occurrenceCountsByID,
            at: questionBook
        )
        try createAnswerBook(
            items: deduplicated.items,
            occurrenceCountsByID: deduplicated.occurrenceCountsByID,
            at: answerBook
        )
        try createKnowledgeBook(items: deduplicated.episodeItems, knowledgeCounts: knowledgeCounts, at: knowledgeBook)
        try syncProblemImages(
            reviewItems: state.items.filter(\.needsReview),
            consecutiveDuplicateItems: deduplicated.consecutiveDuplicateItems,
            under: root
        )
        try stateEncoder.encode(state).write(to: stateURL, options: .atomic)

        // 题库同步是附加产物：JSON、Word 和问题图片已经落盘后才执行。
        // 即使数据库暂时不可写，也不得破坏原有整理结果。
        // 连续误截图和非连续重复记录只保留在整理历史中；可刷题库按题干只同步一份，
        // 避免相同题目的多个截图轮流覆盖同一数据库记录。
        let syncRecords = deduplicated.items.map {
            CapturedQuestionRecord(
                sourcePath: $0.sourcePath,
                sourceHash: $0.sourceHash,
                capturedAt: $0.capturedAt,
                question: $0.question,
                options: $0.options,
                correctAnswer: $0.correctAnswer,
                explanation: $0.explanation,
                knowledgePoints: $0.knowledgePoints,
                needsReview: $0.needsReview
            )
        }
        let questionBankSync = QuestionBankSync().synchronize(syncRecords)
        if questionBankSync.hasFailures {
            FileHandle.standardError.write(Data((questionBankSync.diagnostic + "\n").utf8))
        }

        let repeated = knowledgeCounts.values.filter { $0 >= 2 }.count
        return OrganizerReport(
            newCount: newCount,
            updatedCount: updatedCount,
            totalCount: state.items.count,
            uniqueCount: deduplicated.items.count,
            duplicateCount: deduplicated.duplicateCount,
            repeatedQuestionCount: deduplicated.repeatedQuestionCount,
            ignoredConsecutiveCount: deduplicated.ignoredConsecutiveCount,
            reviewCount: state.items.filter(\.needsReview).count,
            repeatedKnowledgeCount: repeated,
            questionBankSync: questionBankSync,
            questionBook: questionBook,
            answerBook: answerBook,
            knowledgeBook: knowledgeBook
        )
    }

    private func loadState(from url: URL) throws -> OrganizerState {
        guard fileManager.fileExists(atPath: url.path) else { return OrganizerState() }
        let decoded = try stateDecoder.decode(OrganizerState.self, from: Data(contentsOf: url))
        return decoded
    }

    private func discoverImages(under root: URL, excluding output: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let extensions = Set(["png", "jpg", "jpeg", "heic"])
        let rootPath = root.standardizedFileURL.path
        let outputPath = output.standardizedFileURL.path
        let outputIsNested = outputPath != rootPath && outputPath.hasPrefix(rootPath + "/")
        return enumerator.compactMap { entry in
            guard let url = entry as? URL,
                  (!outputIsNested || !url.path.hasPrefix(outputPath + "/")),
                  !url.pathComponents.contains(where: { $0.hasPrefix("待人工校对图片") }),
                  extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true
            else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func recognizeText(in url: URL, recognitionMode: RecognitionMode) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw NSError(domain: "WrongQuestionOrganizer", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取图片：\(url.lastPathComponent)"])
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cropRect: CGRect
        switch recognitionMode {
        case .fentiQuestionBank:
            // 焚题库正文位于窗口左侧。保留接近页面顶端的题干，同时裁掉右侧答题卡。
            cropRect = CGRect(
                x: width * 0.055,
                y: height * 0.035,
                width: width * 0.690,
                height: height * 0.930
            ).integral
        case .general:
            cropRect = CGRect(
                x: width * 0.015,
                y: height * 0.015,
                width: width * 0.970,
                height: height * 0.970
            ).integral
        }
        guard let cropped = image.cropping(to: cropRect) else {
            throw NSError(domain: "WrongQuestionOrganizer", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "无法裁切图片：\(url.lastPathComponent)"])
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        if recognitionMode == .fentiQuestionBank {
            request.customWords = [
                "参考答案", "我的答案", "参考解析", "单选题", "多选题", "判断题",
                "HIV", "Horner综合征", "Duroziez双重杂音", "肾小盏", "麻痹性斜视",
                "Na+", "K+", "促甲状腺激素", "肺动脉瓣狭窄", "前纵韧带", "中度烧伤", "重度烧伤", "特重烧伤",
                "浅II度烧伤", "深II度烧伤", "III度烧伤"
            ]
        }
        try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])

        let observations = (request.results ?? []).sorted {
            let verticalDifference = abs($0.boundingBox.midY - $1.boundingBox.midY)
            if verticalDifference > 0.012 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func parse(rawText: String, recognitionMode: RecognitionMode) -> ParsedQuestion {
        var lines = rawText.components(separatedBy: .newlines)
            .map(cleanLine)
            .filter {
                !$0.isEmpty && (!isInterfaceNoise($0, recognitionMode: recognitionMode) || ExplanationBoundary.isExactMarker($0))
            }

        let questionMarkerPattern = #"\d*\s*[\[［【(（]\s*(单选题|多选题|判断题)\s*[\]］】)）Jj]?"#
        let hasQuestionMarker = lines.contains {
            $0.range(of: questionMarkerPattern, options: .regularExpression) != nil
        }
        let questionIndex = lines.firstIndex { line in
            line.range(of: questionMarkerPattern, options: .regularExpression) != nil ||
            line.contains("单选题") || line.contains("多选题") || line.contains("判断题")
        } ?? 0
        if questionIndex > 0 { lines = Array(lines[questionIndex...]) }

        let answerIndex = lines.firstIndex { $0.contains("参考答案") } ?? lines.count
        let explanationIndex = lines.firstIndex { $0.contains("参考解析") }
        let beforeAnswer = Array(lines.prefix(answerIndex)).flatMap(splitEmbeddedFirstOption)
        let questionStop = beforeAnswer.indices.dropFirst().first { isQuestionAreaStop(beforeAnswer[$0]) }
            ?? beforeAnswer.endIndex
        let questionArea = Array(beforeAnswer[..<questionStop])

        let explicitOptions = questionArea.enumerated().compactMap { index, line -> (Int, String, String)? in
            guard let option = optionComponents(in: line) else { return nil }
            return (index, option.label, option.text)
        }

        var questionLines = questionArea
        var options: [String] = []
        if let first = explicitOptions.first,
           let firstLabelIndex = optionLabelIndex(first.1) {
            // 浅灰色的 A/B/C/D 有时不会被 Vision 识别，但正文仍然存在。
            // 根据相邻已识别选项的顺序恢复标签，不补写任何选项正文。
            let optionStart = max(1, first.0 - firstLabelIndex)
            questionLines = Array(questionArea.prefix(optionStart))
            var recovered: [Int: String] = [:]
            var expected = 0

            for index in optionStart..<questionArea.count {
                let line = questionArea[index]
                if let option = optionComponents(in: line),
                   let labelIndex = optionLabelIndex(option.label), labelIndex < 4 {
                    recovered[labelIndex] = cleanedOptionText(
                        option.text,
                        expectedLabel: option.label,
                        recognitionMode: recognitionMode
                    )
                    expected = max(expected, labelIndex + 1)
                } else if expected < 4 {
                    let label = String(UnicodeScalar(65 + expected)!)
                    guard let text = unlabeledOptionCandidate(from: line, expectedLabel: label) else { continue }
                    recovered[expected] = cleanedOptionText(
                        text,
                        expectedLabel: label,
                        recognitionMode: recognitionMode
                    )
                    expected += 1
                }
            }

            options = (0..<4).compactMap { index in
                guard let text = recovered[index] else { return nil }
                let label = String(UnicodeScalar(65 + index)!)
                return "\(label). \(text)"
            }
        }

        var question = questionLines.joined(separator: " ")
        question = question.replacingOccurrences(
            of: #"^\s*\d+\s*[\[［【(（]\s*(单选题|多选题|判断题)\s*[\]］】)）1lI|｜Jj]?\s*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        question = question.replacingOccurrences(
            of: #"\s+[0oOiIl丨|｜Xx◎○〇×]\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        question = QuestionTextCleanup.removingRepeatedIntroductoryBlock(from: question)
        if recognitionMode == .fentiQuestionBank {
            question = QuestionTextCleanup.removingQuestionBankHeaderArtifacts(from: question)
            question = normalizedFentiMedicalText(question)
        }

        if question.isEmpty {
            question = "[OCR 未能可靠识别题干，请对照原截图]"
        }

        let correctAnswer = extractAnswer(label: "参考答案", lines: lines)
        let userAnswer = extractAnswer(label: "我的答案", lines: lines)
        var explanation = ""
        if let start = explanationIndex {
            let first = lines[start].replacingOccurrences(
                of: #"^.*?参考解析\s*[:：]?\s*"#,
                with: "",
                options: .regularExpression
            )
            var explanationLines = first.isEmpty ? [] : [first]
            if start + 1 < lines.count {
                for index in (start + 1)..<lines.count {
                    let line = lines[index]
                    if ExplanationBoundary.shouldStop(
                        at: line,
                        previousContentLine: explanationLines.last,
                        isLastLine: index == lines.index(before: lines.endIndex)
                    ) { break }
                    explanationLines.append(line)
                }
            }
            explanation = explanationLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if recognitionMode == .fentiQuestionBank {
            explanation = normalizedFentiMedicalText(explanation)
        }
        if explanation.isEmpty { explanation = "待人工补充：截图中未可靠识别到参考解析。" }

        let knowledgePoints = explanation.hasPrefix("待人工补充")
            ? []
            : extractKnowledgePoints(from: explanation, question: question)
        let isBinaryQuestion = questionArea.first?.contains("判断题") == true
        let minimumOptions = isBinaryQuestion ? 2 : 4
        let suspiciousFentiStem = recognitionMode == .fentiQuestionBank &&
            isSuspiciousFentiStem(question, hasQuestionMarker: hasQuestionMarker)
        let suspiciousFentiOptions = recognitionMode == .fentiQuestionBank &&
            options.contains(where: isSuspiciousFentiOption)
        let needsReview = question.hasPrefix("[OCR") || options.count < minimumOptions ||
            correctAnswer == "待校对" || explanation.hasPrefix("待人工补充") ||
            suspiciousFentiStem || suspiciousFentiOptions

        return ParsedQuestion(
            question: question,
            options: options,
            correctAnswer: correctAnswer,
            userAnswer: userAnswer,
            explanation: explanation,
            knowledgePoints: knowledgePoints,
            needsReview: needsReview
        )
    }

    private func cleanLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?<=[\u4E00-\u9FFF，。；：！？、（）“”])\s+(?=[\u4E00-\u9FFF，。；：！？、（）“”])"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isInterfaceNoise(_ line: String, recognitionMode: RecognitionMode) -> Bool {
        let exactNoise: Set<String> = [
            "上一题", "下一题", "查看答案", "试题答疑", "做题笔记", "展开全部解析",
            "收起解析", "答题卡", "收藏", "纠错", "返回", "交卷", "正确", "错误", "确定"
        ]
        if exactNoise.contains(line) { return true }
        if line.range(of: #"^\d+$"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^[iIl丨|｜-]$"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^[iIl丨|｜]?(答|单|多|共)$"#, options: .regularExpression) != nil { return true }
        if line.contains("ICP备") || line.contains("扫码") { return true }
        guard recognitionMode == .fentiQuestionBank else { return false }
        let fentiExactNoise: Set<String> = [
            "首页", "题库", "首页 题库", "焚题库", "焚题库官网", "APP工具", "APP下载",
            "合作加盟", "医学综合", "切换", "章节练习", "模拟试卷"
        ]
        if fentiExactNoise.contains(line) { return true }
        let lowercase = line.lowercased()
        return lowercase.contains("tiku.hkwx8.com") || lowercase.contains("/burn_exam/") ||
            lowercase.contains("http://") || lowercase.contains("https://")
    }

    private func normalizeOption(_ line: String) -> String {
        let normalized = line.replacingOccurrences(of: "Ａ", with: "A")
            .replacingOccurrences(of: "Ｂ", with: "B")
            .replacingOccurrences(of: "Ｃ", with: "C")
            .replacingOccurrences(of: "Ｄ", with: "D")
            .replacingOccurrences(of: "Ｅ", with: "E")
            .replacingOccurrences(of: "Ｆ", with: "F")
            .replacingOccurrences(of: "ａ", with: "a")
            .replacingOccurrences(of: "ｂ", with: "b")
            .replacingOccurrences(of: "ｃ", with: "c")
            .replacingOccurrences(of: "ｄ", with: "d")
            .replacingOccurrences(of: "ｅ", with: "e")
            .replacingOccurrences(of: "ｆ", with: "f")
            .replacingOccurrences(of: #"^[<＜>＞•◎○〇●×✓☑☐□■▢口◉◯⑴-⒇①-⑳xX0Oo~|｜\s]*([A-Fa-f])\s*[、．:]?\s*"#, with: "$1. ", options: .regularExpression)
        guard let first = normalized.first else { return normalized }
        return first.uppercased() + normalized.dropFirst()
    }

    private func optionComponents(in line: String) -> (label: String, text: String)? {
        let normalized = line
            .replacingOccurrences(of: "Ａ", with: "A")
            .replacingOccurrences(of: "Ｂ", with: "B")
            .replacingOccurrences(of: "Ｃ", with: "C")
            .replacingOccurrences(of: "Ｄ", with: "D")
            .replacingOccurrences(of: "Ｅ", with: "E")
            .replacingOccurrences(of: "Ｆ", with: "F")
            .replacingOccurrences(of: "ａ", with: "a")
            .replacingOccurrences(of: "ｂ", with: "b")
            .replacingOccurrences(of: "ｃ", with: "c")
            .replacingOccurrences(of: "ｄ", with: "d")
            .replacingOccurrences(of: "ｅ", with: "e")
            .replacingOccurrences(of: "ｆ", with: "f")
        let pattern = #"^[<＜>＞•◎○〇●×✓☑☐□■▢口◉◯⑴-⒇①-⑳xX0Oo~|｜\s]*([A-Fa-f])\s*[\.、．:]?\s*(\S.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized)
              ),
              let labelRange = Range(match.range(at: 1), in: normalized),
              let textRange = Range(match.range(at: 2), in: normalized)
        else { return nil }
        let label = String(normalized[labelRange]).uppercased()
        let text = String(normalized[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (label, text)
    }

    private func optionLabelIndex(_ label: String) -> Int? {
        guard let scalar = label.uppercased().unicodeScalars.first else { return nil }
        let value = Int(scalar.value) - 65
        return (0..<6).contains(value) ? value : nil
    }

    private func cleanedOptionText(
        _ value: String,
        expectedLabel: String,
        recognitionMode: RecognitionMode
    ) -> String {
        guard recognitionMode == .fentiQuestionBank else { return value }
        var result = QuestionTextCleanup.removingRecoveredOptionPrefix(
            from: value,
            expectedLabel: expectedLabel
        )
            .replacingOccurrences(of: "減", with: "减")
            .replacingOccurrences(of: "黃", with: "黄")
            .replacingOccurrences(of: "淺", with: "浅")
        result = result.replacingOccurrences(
            of: #"(?<=[浅深])(?:\|I|｜I|lI|1I|I\||I｜)(?=\s*度)"#,
            with: "II",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"^O(?=ml$)"#,
            with: "0",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(of: #"(?<=II)\s+(?=度)"#, with: "", options: .regularExpression)
        return normalizedFentiMedicalText(result)
    }

    private func normalizedFentiMedicalText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "Nat-K+", with: "Na+-K+")
            .replacingOccurrences(of: "Nat-K", with: "Na+-K")
            .replacingOccurrences(of: "Na*", with: "Na+")
            .replacingOccurrences(of: "K*", with: "K+")
            .replacingOccurrences(
                of: #"(?<=[浅深])(?:\|I|｜I|lI|1I|I\||I｜)(?=\s*度)"#,
                with: "II",
                options: .regularExpression
            )
    }

    private func unlabeledOptionCandidate(from line: String, expectedLabel: String) -> String? {
        let stripped = line.replacingOccurrences(
            of: #"^[•◎○〇●×✓☑☐□■▢口◉◯⑴-⒇①-⑳xX0Oo~|｜\s]+"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let recovered = QuestionTextCleanup.removingRecoveredOptionPrefix(
            from: stripped,
            expectedLabel: expectedLabel
        )
        guard !recovered.isEmpty,
              recovered.range(of: #"^\d+$"#, options: .regularExpression) == nil,
              recovered.range(of: #"^[iIl丨|｜]?(答|单|多|共)$"#, options: .regularExpression) == nil,
              !isQuestionAreaStop(recovered)
        else { return nil }
        let meaningfulCount = recovered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains(Int($0.value))
        }.count
        return meaningfulCount >= 2 ? recovered : nil
    }

    private func isSuspiciousFentiStem(_ question: String, hasQuestionMarker: Bool) -> Bool {
        if !hasQuestionMarker { return true }
        let lowercase = question.lowercased()
        if lowercase.contains("tiku.hkwx8.com") || lowercase.contains("/burn_exam/") ||
            lowercase.contains("http://") || lowercase.contains("https://") {
            return true
        }
        let meaningfulCount = question.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains(Int($0.value))
        }.count
        guard meaningfulCount < 12 else { return false }
        let compact = question.replacingOccurrences(of: " ", with: "")
        let questionEndings = ["（）", "()", "？", "?", "有", "是", "为", "包括", "不包括"]
        return !questionEndings.contains(where: compact.contains)
    }

    private func isSuspiciousFentiOption(_ option: String) -> Bool {
        if option.contains("*") || option.contains("Nat") || option.contains("mmdl") { return true }
        return option.range(
            of: #"^[A-F]\.\s*[\]］】]|[匕乚]\s*[A-Fa-f]"#,
            options: .regularExpression
        ) != nil
    }

    private func isQuestionAreaStop(_ line: String) -> Bool {
        let stops = ["确定", "回答错误", "回答正确", "参考答案", "我的答案", "收藏本题", "查看解析", "收起解析"]
        if stops.contains(where: line.contains) { return true }
        return line == "错误" || line == "正确"
    }

    private func splitEmbeddedFirstOption(_ line: String) -> [String] {
        let pattern = #"\s+[•◎○●×✓①-⑳\s]*[AＡ]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line),
              line[..<range.lowerBound].contains("）") || line[..<range.lowerBound].contains(")")
        else { return [line] }
        let stem = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let optionText = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return [stem, "A " + optionText]
    }

    private func extractAnswer(label: String, lines: [String]) -> String {
        for (index, line) in lines.enumerated() where line.contains(label) {
            let suffix = line.components(separatedBy: label).dropFirst().joined(separator: label)
            if let answer = firstAnswerLetter(in: suffix) { return answer }
            if index + 1 < lines.count, let answer = firstAnswerLetter(in: lines[index + 1]) {
                return answer
            }
        }
        return "待校对"
    }

    private func firstAnswerLetter(in value: String) -> String? {
        guard let range = value.range(of: #"(?<![A-Za-z])[A-FＡ-Ｆ](?:\s*[,、，]?\s*[A-FＡ-Ｆ])*"#,
                                      options: .regularExpression) else { return nil }
        return String(value[range])
            .uppercased()
            .replacingOccurrences(of: "Ａ", with: "A")
            .replacingOccurrences(of: "Ｂ", with: "B")
            .replacingOccurrences(of: "Ｃ", with: "C")
            .replacingOccurrences(of: "Ｄ", with: "D")
            .replacingOccurrences(of: "Ｅ", with: "E")
            .replacingOccurrences(of: "Ｆ", with: "F")
            .replacingOccurrences(of: #"[^A-F]"#, with: "", options: .regularExpression)
    }

    private func extractKnowledgePoints(from explanation: String, question: String) -> [String] {
        let stopWords: Set<String> = [
            "因为", "所以", "因此", "主要", "一般", "通常", "可以", "能够", "属于", "其中",
            "这种", "这个", "这些", "以及", "对于", "进行", "形成", "存在", "出现", "发生",
            "作用", "原因", "有关", "相关", "方面", "情况", "过程", "结果", "答案", "选项",
            "正确", "错误", "本题", "考查", "大多数", "从而", "由于", "通过", "说明", "解析",
            "患者", "病人", "可见", "可考虑", "表现", "症状", "体征", "部位", "时间", "其他",
            "左侧", "右侧", "前者", "后者", "明显", "可能", "往往", "容易", "同时", "以上",
            "以下", "每日", "每天", "小于", "大于", "增多", "减少", "增高", "降低", "异常",
            "正常", "固定", "单个", "初期", "严重", "常见于", "未见", "符合", "不符", "排除",
            "病史", "查体", "疾病", "考虑", "首先", "诊断", "发病", "进食", "此时", "之势"
        ]
        let tokens = chineseTokens(in: explanation)
        let questionTokens = chineseTokens(in: question)

        let medicalHints = [
            "病", "炎", "症", "癌", "瘤", "中毒", "衰竭", "积液", "压塞", "气肿", "血压",
            "血糖", "血脂", "电位", "步态", "导联", "心电图", "脉搏", "呼吸", "体温", "尿量",
            "细胞", "组织", "器官", "神经", "肌肉", "血管", "激素", "抗体", "抗原", "细菌",
            "病毒", "酶", "电解质", "酸碱", "收缩", "舒张", "心包", "胸膜", "甲状腺", "胰腺"
        ]
        let normalizedExplanation = explanation.replacingOccurrences(of: " ", with: "")
        var scores: [String: Int] = [:]

        // 首选题干与解析共同出现的概念，能显著减少泛化词和断裂词组。
        for start in questionTokens.indices {
            var candidate = ""
            for length in 1...4 where start + length <= questionTokens.count {
                let part = questionTokens[start + length - 1]
                if stopWords.contains(part) { break }
                candidate += part
                guard candidate.count >= 2, candidate.count <= 14,
                      normalizedExplanation.contains(candidate), !stopWords.contains(candidate) else { continue }
                var score = 70 + min(candidate.count, 14)
                if medicalHints.contains(where: candidate.contains) { score += 30 }
                scores[candidate] = max(scores[candidate] ?? 0, score)
            }
        }

        // 再补充解析中明确的医学实体或短词；不把任意三词拼成“知识点”。
        for start in tokens.indices {
            var candidate = ""
            for length in 1...3 where start + length <= tokens.count {
                let part = tokens[start + length - 1]
                if stopWords.contains(part) { break }
                candidate += part
                let chineseCount = candidate.unicodeScalars.filter { (0x4E00...0x9FFF).contains(Int($0.value)) }.count
                guard chineseCount >= 2, candidate.count <= 14, !stopWords.contains(candidate) else { continue }
                let hasMedicalHint = medicalHints.contains(where: candidate.contains)
                if length >= 2 && !hasMedicalHint { continue }
                var score = min(candidate.count, 12)
                if question.contains(candidate) { score += 45 }
                if hasMedicalHint { score += 35 }
                if length == 1 { score += 10 }
                scores[candidate] = max(scores[candidate] ?? 0, score)
            }
        }

        var selected: [String] = []
        for candidate in scores.keys.sorted(by: {
            if scores[$0] != scores[$1] { return (scores[$0] ?? 0) > (scores[$1] ?? 0) }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0 < $1
        }) {
            if selected.contains(where: { $0.contains(candidate) || candidate.contains($0) }) { continue }
            selected.append(candidate)
            if selected.count == 4 { break }
        }
        return selected
    }

    private func chineseTokens(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.simplifiedChinese)
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let chineseCount = token.unicodeScalars.filter { (0x4E00...0x9FFF).contains(Int($0.value)) }.count
            if token.count <= 12, chineseCount >= 1 { result.append(token) }
            return true
        }
        return result
    }

    private func captureDate(for url: URL) -> Date {
        let pattern = #"(\d{8})_(\d{6})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: url.lastPathComponent,
                                        range: NSRange(url.lastPathComponent.startIndex..., in: url.lastPathComponent)),
           let dayRange = Range(match.range(at: 1), in: url.lastPathComponent),
           let timeRange = Range(match.range(at: 2), in: url.lastPathComponent) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMddHHmmss"
            if let date = formatter.date(from: String(url.lastPathComponent[dayRange]) + String(url.lastPathComponent[timeRange])) {
                return date
            }
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    private func knowledgeOccurrenceCounts(in items: [WrongQuestionItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            for point in Set(item.knowledgePoints) { counts[point, default: 0] += 1 }
        }
        return counts
    }

    private func deduplicatedItems(_ items: [WrongQuestionItem]) -> DeduplicationResult {
        var primaryIDByKey: [String: String] = [:]
        var unique: [WrongQuestionItem] = []
        var episodeItems: [WrongQuestionItem] = []
        var consecutiveDuplicateItems: [WrongQuestionItem] = []
        var occurrenceCountsByID: [String: Int] = [:]
        var previousKey: String?
        var ignoredConsecutiveCount = 0
        for item in items {
            let key = duplicateKey(for: item)
            if let primaryID = primaryIDByKey[key] {
                if previousKey == key {
                    ignoredConsecutiveCount += 1
                    consecutiveDuplicateItems.append(item)
                } else {
                    occurrenceCountsByID[primaryID, default: 1] += 1
                    episodeItems.append(item)
                }
            } else {
                primaryIDByKey[key] = item.id
                occurrenceCountsByID[item.id] = 1
                unique.append(item)
                episodeItems.append(item)
            }
            previousKey = key
        }
        return DeduplicationResult(
            items: unique,
            episodeItems: episodeItems,
            consecutiveDuplicateItems: consecutiveDuplicateItems,
            occurrenceCountsByID: occurrenceCountsByID,
            duplicateCount: items.count - unique.count,
            ignoredConsecutiveCount: ignoredConsecutiveCount
        )
    }

    private func duplicateKey(for item: WrongQuestionItem) -> String {
        // 误操作以题干为准：浅色选项标签或 OCR 文字差异不应导致同题漏判。
        // 题干无法识别时不合并，避免把多个不同的 OCR 失败截图误判成同一道题。
        if item.question.hasPrefix("[OCR") { return "unreadable:\(item.sourceHash)" }
        let scalars = item.question.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        let key = String(String.UnicodeScalarView(scalars))
        return key.isEmpty ? "unreadable:\(item.sourceHash)" : key
    }

    private func reviewIssueLabels(for item: WrongQuestionItem) -> [String] {
        var labels: [String] = []
        if item.question.hasPrefix("[OCR") { labels.append("无题干") }
        let minimumOptions = item.rawText.contains("判断题") ? 2 : 4
        if item.options.count < minimumOptions { labels.append("选项不全") }
        if item.correctAnswer == "待校对" { labels.append("无答案") }
        if item.explanation.hasPrefix("待人工补充") { labels.append("无解析") }
        if labels.isEmpty && item.needsReview { labels.append("OCR待校对") }
        return labels
    }

    private func syncProblemImages(
        reviewItems: [WrongQuestionItem],
        consecutiveDuplicateItems: [WrongQuestionItem],
        under root: URL
    ) throws {
        let folder = root.appendingPathComponent("待人工校对图片", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var labelsByPath: [String: [String]] = [:]
        var itemByPath: [String: WrongQuestionItem] = [:]
        for item in consecutiveDuplicateItems {
            labelsByPath[item.sourcePath, default: []].append("重复截图")
            itemByPath[item.sourcePath] = item
        }
        for item in reviewItems {
            labelsByPath[item.sourcePath, default: []].append(contentsOf: reviewIssueLabels(for: item))
            itemByPath[item.sourcePath] = item
        }

        var desiredNames: Set<String> = []
        for path in labelsByPath.keys.sorted() {
            guard let item = itemByPath[path] else { continue }
            var labels: [String] = []
            for label in labelsByPath[path] ?? [] where !labels.contains(label) {
                labels.append(label)
            }
            let source = URL(fileURLWithPath: path)
            let filename = "\(labels.joined(separator: "_"))_\(item.id)_\(source.lastPathComponent)"
            desiredNames.insert(filename)
            let destination = folder.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destination.path) { continue }
            try fileManager.copyItem(at: source, to: destination)
        }

        let managedPattern = try NSRegularExpression(pattern: #"^.*WQ\d{4}_"#)
        for existing in try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let name = existing.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard managedPattern.firstMatch(in: name, range: range) != nil,
                  !desiredNames.contains(name)
            else { continue }
            try fileManager.removeItem(at: existing)
        }
    }

    private func createQuestionBook(
        items: [WrongQuestionItem],
        occurrenceCountsByID: [String: Int],
        at output: URL
    ) throws {
        var body = coverHTML(
            title: "医学综合错题本",
            subtitle: "纯题版 · 截图即收录",
            itemCount: items.count,
            note: "本册不含答案与解析，适合打印后独立练习。页面显示答对的截图也会收录，因为其中可能包含随机猜对或尚未掌握的内容。"
        )
        for item in items {
            body += "<section class='question'>"
            body += "<h2>\(html(item.id)) <span class='date'>\(html(shortDate(item.capturedAt)))</span></h2>"
            if let count = occurrenceCountsByID[item.id], count >= 2 {
                body += "<p class='repeat-badge'>重复出现 \(count) 次 · 仍未掌握</p>"
            }
            body += "<p class='stem'>\(html(item.question))</p>"
            if item.options.isEmpty {
                body += "<p class='review'>选项待人工校对，请对照原截图。</p>"
            } else {
                body += "<ol class='options'>" + item.options.map { "<li>\(html($0))</li>" }.joined() + "</ol>"
            }
            body += "<p class='answer-space'>作答：________________________</p>"
            body += "</section>"
        }
        try convertHTMLToDocx(documentHTML(title: "医学综合错题本_纯题", body: body), output: output)
    }

    private func createAnswerBook(
        items: [WrongQuestionItem],
        occurrenceCountsByID: [String: Int],
        at output: URL
    ) throws {
        var body = coverHTML(
            title: "医学综合错题本",
            subtitle: "答案与解析",
            itemCount: items.count,
            note: "本册与纯题版题号一一对应，只保留参考答案、截图中的作答和原页面解析。薄弱知识点已另行整理成独立文档。"
        )
        for item in items {
            body += "<section class='question'>"
            body += "<h2>\(html(item.id)) <span class='date'>\(html(shortDate(item.capturedAt)))</span></h2>"
            if let count = occurrenceCountsByID[item.id], count >= 2 {
                body += "<p class='repeat-badge'>重复出现 \(count) 次 · 仍未掌握</p>"
            }
            body += "<p class='stem'>\(html(item.question))</p>"
            body += "<div class='answer'><b>参考答案：</b>\(html(item.correctAnswer))"
            body += "　<b>截图中的作答：</b>\(html(item.userAnswer))</div>"
            body += "<h3>参考解析</h3><p>\(html(item.explanation))</p>"
            if item.needsReview {
                body += "<p class='review'>⚠ 本题存在 OCR 缺项，请对照原截图人工校对。</p>"
            }
            body += "<p class='source'>截图：\(html(relativeSourcePath(item.sourcePath)))</p>"
            body += "</section>"
        }
        try convertHTMLToDocx(documentHTML(title: "医学综合错题本_答案与解析", body: body), output: output)
    }

    private func createKnowledgeBook(
        items: [WrongQuestionItem],
        knowledgeCounts: [String: Int],
        at output: URL
    ) throws {
        let repeated = knowledgeCounts.filter { $0.value >= 2 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let single = knowledgeCounts.filter { $0.value == 1 }.map(\.key).sorted()
        var itemIDsByPoint: [String: [String]] = [:]
        for item in items {
            for point in Set(item.knowledgePoints) {
                itemIDsByPoint[point, default: []].append(item.id)
            }
        }

        var body = coverHTML(
            title: "医学综合错题本",
            subtitle: "薄弱知识点",
            itemCount: knowledgeCounts.count,
            itemUnit: "条",
            note: "知识点仅从截图中已经识别到的文字自动归纳，不补写外部内容。出现两次或以上的知识点用红色标出，表示经两次记录仍需重点巩固。当前重点：\(repeated.count) 个。"
        )

        body += "<section class='knowledge-section'><h2>重点巩固：两次或以上</h2>"
        if repeated.isEmpty {
            body += "<p>当前没有重复出现的知识点。</p>"
        } else {
            body += "<ol class='knowledge-index'>"
            for (point, count) in repeated {
                let ids = (itemIDsByPoint[point] ?? []).sorted().joined(separator: "、")
                body += "<li class='repeat'><b>\(html(point))</b>"
                body += "<div>累计 \(count) 次 · 重复出现，仍未掌握</div>"
                body += "<div class='related'>关联题目：\(html(ids))</div></li>"
            }
            body += "</ol>"
        }
        body += "</section>"

        body += "<section class='knowledge-section'><h2>待巩固：出现一次</h2>"
        if single.isEmpty {
            body += "<p>当前没有仅出现一次的知识点。</p>"
        } else {
            body += "<ol class='knowledge-index'>"
            for point in single {
                let ids = (itemIDsByPoint[point] ?? []).sorted().joined(separator: "、")
                body += "<li><b>\(html(point))</b><div class='related'>关联题目：\(html(ids))</div></li>"
            }
            body += "</ol>"
        }
        body += "</section>"

        let missing = items.filter { $0.knowledgePoints.isEmpty }.map(\.id)
        if !missing.isEmpty {
            body += "<section class='knowledge-section'><h2>待人工补充</h2>"
            body += "<p class='review'>以下题目未能从现有解析中可靠抽取知识点：\(html(missing.joined(separator: "、")))。</p></section>"
        }
        try convertHTMLToDocx(documentHTML(title: "医学综合错题本_薄弱知识点", body: body), output: output)
    }

    private func coverHTML(title: String, subtitle: String, itemCount: Int, itemUnit: String = "题", note: String) -> String {
        """
        <section class='cover'>
          <div class='kicker'>成人高考专升本 · 医学综合</div>
          <h1>\(html(title))</h1>
          <div class='subtitle'>\(html(subtitle))</div>
          <div class='rule'></div>
          <p>当前收录：<b>\(itemCount)</b> \(html(itemUnit))</p>
          <p>生成时间：\(html(fullDate(Date())))</p>
          <div class='cover-note'>\(html(note))</div>
        </section>
        <div class='page-break'></div>
        """
    }

    private func documentHTML(title: String, body: String) -> String {
        """
        <!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><title>\(html(title))</title>
        <style>
          @page { size: Letter portrait; margin: 1in; }
          body { font-family: 'Arial Unicode MS', 'PingFang SC', 'Songti SC', sans-serif; font-size: 11pt; line-height: 1.25; color: #222; margin: 0; }
          .cover { min-height: 8.2in; padding-top: 1.25in; }
          .kicker { color: #2E74B5; font-size: 11pt; letter-spacing: 1px; margin-bottom: 18pt; }
          h1 { color: #2E74B5; font-size: 24pt; margin: 0 0 10pt; }
          .subtitle { color: #1F4D78; font-size: 16pt; margin-bottom: 18pt; }
          .rule { height: 3px; background: #2E74B5; width: 1.6in; margin: 18pt 0 24pt; }
          .cover-note { margin-top: 30pt; padding: 12pt; background: #E8EEF5; border-left: 4px solid #2E74B5; }
          .page-break { page-break-after: always; }
          .question { page-break-inside: avoid; border-bottom: 1px solid #D9E1E8; padding: 0 0 10pt; margin: 0 0 12pt; }
          h2 { color: #2E74B5; font-size: 16pt; margin: 18pt 0 10pt; }
          h3 { color: #1F4D78; font-size: 12pt; margin: 10pt 0 5pt; }
          p { margin: 0 0 6pt; }
          .date { float: right; color: #777; font-size: 9pt; font-weight: normal; }
          .stem { font-weight: 600; }
          .options { list-style: none; margin: 4pt 0 8pt 0; padding: 0; }
          .options li { margin: 2pt 0; }
          .answer-space { color: #666; margin-top: 8pt; }
          .answer { background: #E8EEF5; padding: 7pt 9pt; margin: 6pt 0; }
          .knowledge { margin: 3pt 0 7pt 18pt; padding: 0; }
          .knowledge li { margin: 2pt 0; }
          .knowledge-section { margin-bottom: 18pt; }
          .knowledge-index { margin: 5pt 0 10pt 20pt; padding: 0; }
          .knowledge-index li { margin: 0 0 9pt; page-break-inside: avoid; }
          .related { color: #666; font-size: 9pt; margin-top: 2pt; }
          .repeat { color: #C00000; }
          .repeat-badge { color: #C00000; font-weight: 700; margin: -4pt 0 7pt; }
          .review { color: #C00000; font-weight: 600; }
          .source { color: #777; font-size: 8pt; margin-top: 7pt; }
        </style></head><body>\(body)</body></html>
        """
    }

    private func convertHTMLToDocx(_ source: String, output: URL) throws {
        let temporaryHTML = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).html")
        let temporaryDocx = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).docx")
        let correctedDocx = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-cjk.docx")
        defer {
            try? fileManager.removeItem(at: temporaryHTML)
            try? fileManager.removeItem(at: temporaryDocx)
            try? fileManager.removeItem(at: correctedDocx)
        }
        try Data(source.utf8).write(to: temporaryHTML, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", "-format", "html", "-output", temporaryDocx.path, temporaryHTML.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fileManager.fileExists(atPath: temporaryDocx.path) else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "WrongQuestionOrganizer", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "生成 Word 文档失败：\(message)"])
        }
        try addEastAsianFontMetadata(to: temporaryDocx, output: correctedDocx)
        if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
        try fileManager.moveItem(at: correctedDocx, to: output)
    }

    private func addEastAsianFontMetadata(to source: URL, output: URL) throws {
        let working = source.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-docx", isDirectory: true)
        try fileManager.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: working) }

        try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-q", source.path, "-d", working.path]
        )
        let documentXML = working.appendingPathComponent("word/document.xml")
        var xml = try String(contentsOf: documentXML, encoding: .utf8)
        xml = xml.replacingOccurrences(
            of: "<w:rFonts ",
            with: "<w:rFonts w:eastAsia=\"Noto Sans CJK SC\" "
        )
        // textutil 会给每个字符运行写入 0 间距；LibreOffice 对 CJK 的兼容实现会把它误判为零字宽。
        xml = xml.replacingOccurrences(of: "<w:spacing w:val=\"0\"/>", with: "")
        try Data(xml.utf8).write(to: documentXML, options: .atomic)
        try installEmbeddedCJKFont(into: working)
        try runProcess(
            executable: "/usr/bin/zip",
            arguments: ["-q", "-r", output.path, "."],
            currentDirectory: working
        )
    }

    private func installEmbeddedCJKFont(into working: URL) throws {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("DocxFonts", isDirectory: true),
              fileManager.fileExists(atPath: resources.appendingPathComponent("font1.odttf").path)
        else {
            throw NSError(domain: "WrongQuestionOrganizer", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "应用缺少 Word 中文字体资源，请重新安装完整应用。"])
        }

        let fontsFolder = working.appendingPathComponent("word/fonts", isDirectory: true)
        let relationshipsFolder = working.appendingPathComponent("word/_rels", isDirectory: true)
        try fileManager.createDirectory(at: fontsFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: relationshipsFolder, withIntermediateDirectories: true)
        try fileManager.copyItem(at: resources.appendingPathComponent("font1.odttf"),
                                 to: fontsFolder.appendingPathComponent("font1.odttf"))
        try fileManager.copyItem(at: resources.appendingPathComponent("font2.odttf"),
                                 to: fontsFolder.appendingPathComponent("font2.odttf"))
        try fileManager.copyItem(at: resources.appendingPathComponent("fontTable.xml"),
                                 to: working.appendingPathComponent("word/fontTable.xml"))
        try fileManager.copyItem(at: resources.appendingPathComponent("fontTable.xml.rels"),
                                 to: relationshipsFolder.appendingPathComponent("fontTable.xml.rels"))

        let contentTypesURL = working.appendingPathComponent("[Content_Types].xml")
        var contentTypes = try String(contentsOf: contentTypesURL, encoding: .utf8)
        let declarations = """
        <Default Extension="odttf" ContentType="application/vnd.openxmlformats-officedocument.obfuscatedFont"/>
        <Override PartName="/word/fontTable.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"/>
        """
        contentTypes = contentTypes.replacingOccurrences(of: "</Types>", with: declarations + "</Types>")
        try Data(contentTypes.utf8).write(to: contentTypesURL, options: .atomic)

        let documentRelationshipsURL = relationshipsFolder.appendingPathComponent("document.xml.rels")
        var relationships = try String(contentsOf: documentRelationshipsURL, encoding: .utf8)
        let fontRelationship = "<Relationship Id=\"rIdDocxFontTable\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable\" Target=\"fontTable.xml\"/>"
        relationships = relationships.replacingOccurrences(
            of: "</Relationships>",
            with: fontRelationship + "</Relationships>"
        )
        try Data(relationships.utf8).write(to: documentRelationshipsURL, options: .atomic)
    }

    private func runProcess(executable: String, arguments: [String], currentDirectory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "WrongQuestionOrganizer", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "修正 Word 中文字体失败：\(message)"])
        }
    }

    private func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func relativeSourcePath(_ path: String) -> String {
        let marker = "/错题截图/"
        if let range = path.range(of: marker) { return String(path[range.upperBound...]) }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
