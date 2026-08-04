import Foundation

/// Keeps page controls out of an explanation while retaining normal medical text.
public enum ExplanationBoundary {
    private static let markers = [
        "试题答疑", "做题笔记", "上一题", "下一题", "查看答案", "答题卡", "章节练习"
    ]

    /// Exact boundary text must survive the general page-noise filter so the
    /// explanation parser can see it and stop at the correct position.
    public static func isExactMarker(_ line: String) -> Bool {
        markers.contains { line.contains($0) }
    }

    public static func shouldStop(
        at line: String,
        previousContentLine: String?,
        isLastLine: Bool
    ) -> Bool {
        if isExactMarker(line) { return true }

        let compact = line.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
        guard !compact.isEmpty else { return false }

        // The page's “做题笔记” button is frequently recognized as variants such
        // as “放题笔讥” or “玫题笔订”.
        if compact.count <= 6, compact.contains("笔") { return true }

        // Older screenshots include small answer-card labels such as “口5”.
        if compact.range(
            of: #"^[口囗〇○□▢Oo0]?\d{1,2}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        // A clipped four-character button can be completely misrecognized
        // (“半旺处堅” in the existing set). Only treat it as a boundary when it
        // is the final OCR line and follows a complete sentence.
        if isLastLine,
           compact == "半旺处堅",
           previousContentLine?.range(of: #"[。！？；]$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }
}
