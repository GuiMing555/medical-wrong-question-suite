import Foundation

public enum QuestionTextCleanup {
    /// Removes a duplicated case summary when the page header and question body
    /// contain the same multi-sentence text.
    public static func removingRepeatedIntroductoryBlock(from question: String) -> String {
        let segments = question.components(separatedBy: "。")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard segments.count >= 5 else { return question }

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
        return question
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
