using System.Text.RegularExpressions;

namespace WrongQuestionCapture.Windows;

internal sealed partial class QuestionTextParser
{
    private static readonly string[] InterfaceNoise =
    [
        "上一题", "下一题", "答题卡", "查看答案", "收藏本题", "试题答疑", "做题笔记", "章节练习", "提交答案"
    ];

    public ParsedCapturedQuestion Parse(string rawText)
    {
        var lines = rawText.Replace("\r", string.Empty)
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(Clean)
            .Where(line => line.Length > 0 && !InterfaceNoise.Any(noise => line.Contains(noise, StringComparison.Ordinal)))
            .ToList();

        var questionMarker = lines.FindIndex(line =>
            line.Contains("单选题", StringComparison.Ordinal) ||
            line.Contains("多选题", StringComparison.Ordinal) ||
            line.Contains("判断题", StringComparison.Ordinal));
        if (questionMarker > 0) lines = lines.Skip(questionMarker).ToList();

        var answerIndex = lines.FindIndex(IsAnswerLine);
        var explanationIndex = lines.FindIndex(IsExplanationLine);
        var questionEnd = answerIndex >= 0 ? answerIndex : explanationIndex >= 0 ? explanationIndex : lines.Count;
        var questionArea = lines.Take(questionEnd).ToList();
        var expanded = ExpandEmbeddedOptions(questionArea);
        var optionStart = -1;
        for (var index = 0; index < expanded.Count; index++)
        {
            if (!TryParseOption(expanded[index], out var option)) continue;
            optionStart = Math.Max(1, index - LabelIndex(option.Label));
            break;
        }

        IEnumerable<string> stemLines = optionStart >= 0 ? expanded.Take(optionStart) : expanded;
        var stem = CleanStem(string.Join(" ", stemLines));
        IEnumerable<string> optionLines = optionStart >= 0 ? expanded.Skip(optionStart) : Array.Empty<string>();
        var options = ExtractOptions(optionLines);
        var correctLabels = ExtractCorrectLabels(lines, answerIndex);
        var explanation = ExtractExplanation(lines, explanationIndex);
        var knowledgePoints = KnowledgePointExtractor.Extract(stem, explanation, lines);

        var issues = new List<string>();
        if (string.IsNullOrWhiteSpace(stem)) issues.Add("无题干");
        var minimumOptions = rawText.Contains("判断题", StringComparison.Ordinal) ? 2 : 4;
        if (options.Count < minimumOptions) issues.Add("选项不全");
        if (correctLabels.Count == 0 || !correctLabels.IsSubsetOf(options.Select(value => value.Label).ToHashSet(StringComparer.Ordinal)))
            issues.Add("无答案");
        if (string.IsNullOrWhiteSpace(explanation)) issues.Add("无解析");

        return new ParsedCapturedQuestion(stem, options, correctLabels, explanation, knowledgePoints, issues.Distinct().ToArray());
    }

    private static List<string> ExpandEmbeddedOptions(IEnumerable<string> source)
    {
        var result = new List<string>();
        foreach (var line in source)
        {
            var matches = EmbeddedOptionRegex().Matches(line);
            if (matches.Count == 0)
            {
                result.Add(line);
                continue;
            }

            var prefix = line[..matches[0].Index].Trim();
            if (prefix.Length > 0) result.Add(prefix);
            for (var index = 0; index < matches.Count; index++)
            {
                var start = matches[index].Index;
                var end = index + 1 < matches.Count ? matches[index + 1].Index : line.Length;
                result.Add(line[start..end].Trim());
            }
        }
        return result;
    }

    private static List<ParsedOption> ExtractOptions(IEnumerable<string> lines)
    {
        var materialized = lines.ToList();
        var explicitOptions = materialized.Select(line => TryParseOption(line, out var option) ? option : null)
            .Where(option => option is not null)
            .Cast<ParsedOption>()
            .ToArray();
        var targetCount = Math.Max(4, explicitOptions.Select(option => LabelIndex(option.Label) + 1).DefaultIfEmpty(0).Max());
        var options = new Dictionary<string, ParsedOption>(StringComparer.Ordinal);
        var expectedIndex = 0;
        foreach (var line in materialized)
        {
            if (TryParseOption(line, out var option))
            {
                options.TryAdd(option.Label, option);
                expectedIndex = Math.Max(expectedIndex, LabelIndex(option.Label) + 1);
            }
            else if (expectedIndex < targetCount && IsUnlabeledOptionCandidate(line))
            {
                var label = ((char)('A' + expectedIndex)).ToString();
                options.TryAdd(label, new ParsedOption(label, line.Trim()));
                expectedIndex++;
            }
        }
        return options.Values.OrderBy(value => value.Label, StringComparer.Ordinal).ToList();
    }

    private static int LabelIndex(string label) => label.Length == 1 && label[0] is >= 'A' and <= 'F' ? label[0] - 'A' : 0;

    private static bool IsUnlabeledOptionCandidate(string line) =>
        line.Length is >= 1 and <= 140 &&
        !IsAnswerLine(line) && !IsExplanationLine(line) &&
        !InterfaceNoise.Any(noise => line.Contains(noise, StringComparison.Ordinal));

    private static bool TryParseOption(string line, out ParsedOption option)
    {
        var match = OptionRegex().Match(line);
        if (!match.Success)
        {
            option = new ParsedOption(string.Empty, string.Empty);
            return false;
        }
        var label = NormalizeLetters(match.Groups[1].Value);
        var text = match.Groups[2].Value.Trim();
        option = new ParsedOption(label, text);
        return text.Length > 0;
    }

    private static HashSet<string> ExtractCorrectLabels(IReadOnlyList<string> lines, int answerIndex)
    {
        if (answerIndex < 0) return new HashSet<string>(StringComparer.Ordinal);
        var scope = string.Join(" ", lines.Skip(answerIndex).Take(2));
        var labelPosition = scope.IndexOfAny(['：', ':']);
        if (labelPosition >= 0) scope = scope[(labelPosition + 1)..];
        var stop = new[] { "您的答案", "我的答案", "作答", "参考解析", "解析" }
            .Select(value => scope.IndexOf(value, StringComparison.Ordinal))
            .Where(value => value >= 0)
            .DefaultIfEmpty(scope.Length)
            .Min();
        scope = scope[..stop];
        var match = AnswerLettersRegex().Match(scope);
        if (!match.Success) return new HashSet<string>(StringComparer.Ordinal);
        return NormalizeLetters(match.Value).Where(character => character is >= 'A' and <= 'F')
            .Select(character => character.ToString()).ToHashSet(StringComparer.Ordinal);
    }

    private static string ExtractExplanation(IReadOnlyList<string> lines, int explanationIndex)
    {
        if (explanationIndex < 0) return string.Empty;
        var values = lines.Skip(explanationIndex).ToList();
        values[0] = ExplanationPrefixRegex().Replace(values[0], string.Empty).Trim();
        return string.Join(" ", values.TakeWhile(line => !InterfaceNoise.Any(noise => line.Contains(noise, StringComparison.Ordinal))))
            .Trim();
    }

    private static bool IsAnswerLine(string line) =>
        line.Contains("参考答案", StringComparison.Ordinal) ||
        line.StartsWith("正确答案", StringComparison.Ordinal) ||
        line.StartsWith("答案：", StringComparison.Ordinal) ||
        line.StartsWith("答案:", StringComparison.Ordinal);

    private static bool IsExplanationLine(string line) =>
        line.Contains("参考解析", StringComparison.Ordinal) ||
        line.StartsWith("解析：", StringComparison.Ordinal) ||
        line.StartsWith("解析:", StringComparison.Ordinal);

    private static string CleanStem(string value) => QuestionPrefixRegex().Replace(value, string.Empty).Trim();

    private static string Clean(string value) => value
        .Replace('Ａ', 'A').Replace('Ｂ', 'B').Replace('Ｃ', 'C').Replace('Ｄ', 'D').Replace('Ｅ', 'E').Replace('Ｆ', 'F')
        .Replace('\u3000', ' ').Trim();

    private static string NormalizeLetters(string value) => Clean(value).ToUpperInvariant();

    [GeneratedRegex(@"(?<![A-Za-z])([A-FＡ-Ｆ])\s*[\.\uff0e、:：](?=\s*\S)", RegexOptions.IgnoreCase)]
    private static partial Regex EmbeddedOptionRegex();

    [GeneratedRegex(@"^\s*([A-FＡ-Ｆ])(?:\s*[\.\uff0e、:：\)\uff09]\s*|\s+)(.+?)\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex OptionRegex();

    [GeneratedRegex(@"(?<![A-Za-z])[A-FＡ-Ｆ](?:\s*[,\u3001，]?\s*[A-FＡ-Ｆ])*", RegexOptions.IgnoreCase)]
    private static partial Regex AnswerLettersRegex();

    [GeneratedRegex(@"^\s*\d*\s*[\[［【\(（]?\s*(?:单选题|多选题|判断题)?\s*[\]］】\)）]?\s*")]
    private static partial Regex QuestionPrefixRegex();

    [GeneratedRegex(@"^.*?(?:参考解析|解析)\s*[:：]?\s*")]
    private static partial Regex ExplanationPrefixRegex();
}
