import Foundation

enum ExplanationOptionLabelMapper {
    static func displayText(_ explanation: String, options: [PracticeOption]) -> String {
        let mappings = options.enumerated().compactMap { index, option -> (String, String)? in
            guard let original = option.originalLabel?.uppercased(), !original.isEmpty else { return nil }
            return (original, displayLabel(for: index))
        }
        guard mappings.contains(where: { $0.0 != $0.1 }) else { return explanation }

        // Placeholders make swaps such as A->C and C->A simultaneous instead of cascading.
        var result = explanation
        var placeholders: [(String, String)] = []
        for (index, mapping) in mappings.enumerated() where mapping.0 != mapping.1 {
            let placeholder = "§OPTION_LABEL_\(index)§"
            let escaped = NSRegularExpression.escapedPattern(for: mapping.0)
            let patterns = [
                "(?<![A-Za-z])\(escaped)(?=项|、|。|\\.|,|，|：|:|）|\\)|\\s)",
                "(?<=选项)\(escaped)(?![A-Za-z])"
            ]
            for pattern in patterns {
                result = replacing(pattern: pattern, in: result, with: placeholder)
            }
            placeholders.append((placeholder, mapping.1))
        }
        for (placeholder, label) in placeholders {
            result = result.replacingOccurrences(of: placeholder, with: label)
        }
        return result
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private static func displayLabel(for index: Int) -> String {
        guard index < 26, let scalar = UnicodeScalar(65 + index) else { return String(index + 1) }
        return String(scalar)
    }
}
