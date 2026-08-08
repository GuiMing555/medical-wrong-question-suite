import Foundation

public enum QuestionTextCleanup {
    /// Removes a duplicated case summary when the page header and question body
    /// contain the same text.
    public static func removingRepeatedIntroductoryBlock(from question: String) -> String {
        let segments = question.components(separatedBy: "。")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard segments.count >= 3 else { return question }

        if segments.count >= 5 {
            let maximumLength = min(3, segments.count / 2)
            for length in stride(from: maximumLength, through: 2, by: -1) {
                let prefix = Array(segments.prefix(length)).map(normalizedForComparison)
                guard prefix.joined().count >= 30 else { continue }

                for start in length...(segments.count - length) {
                    let candidate = segments[start..<(start + length)].map(normalizedForComparison)
                    guard candidate == prefix else { continue }
                    return cleanLeadingPageMarker(segments[start...].joined(separator: "。"))
                }
            }
        }

        // 焚题库的病例摘要有时是一整句。页面标题与题目正文各出现一次时，
        // OCR 会得到“长句 + 同一长句 + 提问”，需要单独处理这一种结构。
        let first = normalizedForComparison(segments[0])
        guard first.count >= 30 else { return question }
        for start in 1..<segments.count where normalizedForComparison(segments[start]) == first {
            return cleanLeadingPageMarker(segments[start...].joined(separator: "。"))
        }
        return question
    }

    /// Removes OCR debris that was attached to a missing option label, such as
    /// `<D3级`, `1B 前纵韧带`, or `乙B促甲状腺激素`.
    public static func removingRecoveredOptionPrefix(from value: String, expectedLabel: String) -> String {
        let escapedLabel = NSRegularExpression.escapedPattern(for: expectedLabel.uppercased())
        let pattern = "^[<＜>＞\\]］】)）·•0-9一二三四五六七八九十甲乙丙丁戊己庚辛壬癸\\s]+" +
            escapedLabel + "[\\.、．:：\\s]*"
        let cleaned = value.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? value : cleaned
    }

    /// Removes small header remnants that appear before the actual case stem on
    /// the question-bank page. It only removes text that is repeated later or a
    /// short fragment immediately before a standard age-and-sex case opening.
    public static func removingQuestionBankHeaderArtifacts(from question: String) -> String {
        let segments = question.components(separatedBy: "。")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if segments.count >= 2 {
            let first = normalizedForComparison(segments[0])
            let remainder = segments.dropFirst().joined(separator: "。")
            if (10...40).contains(first.count), normalizedForComparison(remainder).contains(first) {
                return remainder
            }
        }

        let pattern = #"^(.{1,18}。)(?=[男女]\s*[，,]\s*\d+\s*岁)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)),
              let prefixRange = Range(match.range(at: 1), in: question)
        else { return question }
        let meaningfulCount = question[prefixRange].unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains(Int($0.value))
        }.count
        guard meaningfulCount <= 10 else { return question }
        return String(question[prefixRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedForComparison(_ value: String) -> String {
        cleanLeadingPageMarker(value).replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func cleanLeadingPageMarker(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"^[iIl丨|｜-]+\s*"#,
            with: "",
            options: .regularExpression
        )
    }
}
