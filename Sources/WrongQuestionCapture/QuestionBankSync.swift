import CryptoKit
import Foundation
import QuestionBankCore

struct CapturedQuestionRecord {
    let sourcePath: String
    let sourceHash: String
    let capturedAt: Date
    let question: String
    let options: [String]
    let correctAnswer: String
    let explanation: String
    let knowledgePoints: [String]
    let needsReview: Bool
}

struct QuestionBankSyncReport {
    var insertedCount = 0
    var updatedCount = 0
    var unchangedCount = 0
    var skippedReviewCount = 0
    var failures: [String] = []

    var synchronizedCount: Int { insertedCount + updatedCount + unchangedCount }
    var changedCount: Int { insertedCount + updatedCount }
    var hasFailures: Bool { !failures.isEmpty }

    var summary: String {
        var value = "练习题库：已同步 \(synchronizedCount) 个截图记录"
        if skippedReviewCount > 0 {
            value += "，\(skippedReviewCount) 张待校对图片未进入可刷题库"
        }
        if !failures.isEmpty {
            value += "，\(failures.count) 项同步失败（不影响 JSON 和 Word 文档）"
        }
        return value + "。"
    }

    var diagnostic: String {
        guard !failures.isEmpty else { return summary }
        return summary + "\n" + failures.prefix(20).map { "- \($0)" }.joined(separator: "\n")
    }
}

final class QuestionBankSync {
    private let databaseURLProvider: () throws -> URL

    init(databaseURLProvider: @escaping () throws -> URL = { try QuestionBankPaths.defaultDatabaseURL() }) {
        self.databaseURLProvider = databaseURLProvider
    }

    func synchronize(_ records: [CapturedQuestionRecord]) -> QuestionBankSyncReport {
        var report = QuestionBankSyncReport()
        report.skippedReviewCount = records.filter(\.needsReview).count
        let eligible = records.filter { !$0.needsReview }
        guard !eligible.isEmpty else { return report }

        let store: QuestionBankStore
        let databaseURL: URL
        do {
            databaseURL = try databaseURLProvider()
            store = try QuestionBankStore(databaseURL: databaseURL, sourceApplication: "capture")
            try store.migrate()
        } catch {
            report.failures.append("无法打开共享题库：\(error.localizedDescription)")
            return report
        }

        for record in eligible {
            do {
                let draft = try makeDraft(from: record)
                // 截图同步只导入题目；错题状态只由实际答错或用户明确标记产生。
                let result = try store.importCapturedQuestion(draft)
                switch result.status {
                case .inserted: report.insertedCount += 1
                case .updated: report.updatedCount += 1
                case .unchanged: report.unchangedCount += 1
                }
            } catch {
                report.failures.append("\(URL(fileURLWithPath: record.sourcePath).lastPathComponent)：\(error.localizedDescription)")
            }
        }

        return report
    }

    private func makeDraft(from record: CapturedQuestionRecord) throws -> CapturedQuestionDraft {
        let parsedOptions = record.options.enumerated().map { index, raw in
            let fallback = String(UnicodeScalar(65 + index)!)
            let parsed = splitOption(raw, fallbackLabel: fallback)
            return CapturedQuestionOption(originalLabel: parsed.label, text: parsed.text)
        }
        let correctLabels = CapturedQuestionDraft.labels(from: record.correctAnswer)
        let availableLabels = Set(parsedOptions.map { $0.originalLabel.uppercased() })
        guard !correctLabels.isEmpty, correctLabels.isSubset(of: availableLabels) else {
            throw NSError(
                domain: "QuestionBankSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "参考答案无法与选项对应"]
            )
        }

        return CapturedQuestionDraft(
            stableExternalID: stableExternalID(for: record.question),
            stem: record.question,
            options: parsedOptions,
            correctLabels: correctLabels,
            explanation: record.explanation,
            knowledgePoints: record.knowledgePoints,
            sourceImagePath: record.sourcePath,
            sourceImageHash: record.sourceHash,
            capturedAt: record.capturedAt,
            source: "capture"
        )
    }

    private func splitOption(_ raw: String, fallbackLabel: String) -> (label: String, text: String) {
        let pattern = #"^\s*([A-Fa-f])\s*[\.．、:：]?\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let labelRange = Range(match.range(at: 1), in: raw),
              let textRange = Range(match.range(at: 2), in: raw)
        else {
            return (fallbackLabel, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (
            String(raw[labelRange]).uppercased(),
            String(raw[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func stableExternalID(for question: String) -> String {
        let scalars = question.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        let normalized = String(String.UnicodeScalarView(scalars))
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "capture:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
