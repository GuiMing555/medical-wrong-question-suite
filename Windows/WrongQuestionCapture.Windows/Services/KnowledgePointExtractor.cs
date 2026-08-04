using System.Text.RegularExpressions;

namespace WrongQuestionCapture.Windows;

internal static partial class KnowledgePointExtractor
{
    private static readonly string[] KnownTerms =
    [
        "细胞膜", "动作电位", "静息电位", "神经递质", "酸碱平衡", "水电解质平衡", "血液循环", "呼吸调节",
        "肾小球滤过", "肾小管重吸收", "激素调节", "凝血功能", "血压", "心排出量", "肺活量", "胃酸", "胆汁",
        "贫血", "休克", "心力衰竭", "呼吸衰竭", "肾功能衰竭", "高血压", "糖尿病", "甲状腺", "胰岛素",
        "炎症", "发热", "水肿", "缺氧", "酸中毒", "碱中毒", "血栓", "栓塞", "棗瘤", "坏死", "萎缩", "增生"
    ];

    public static IReadOnlyList<string> Extract(string stem, string explanation, IReadOnlyList<string> allLines)
    {
        var explicitPoints = allLines.SelectMany(line => ExplicitKnowledgeRegex().Matches(line).Select(match => match.Groups[1].Value.Trim()))
            .Where(value => value.Length is >= 2 and <= 30)
            .Distinct(StringComparer.Ordinal)
            .Take(4)
            .ToList();
        if (explicitPoints.Count > 0) return explicitPoints;

        var source = stem + " " + explanation;
        var values = KnownTerms.Where(source.Contains).Distinct(StringComparer.Ordinal).Take(4).ToList();
        foreach (Match match in MedicalTermRegex().Matches(source))
        {
            var value = match.Value.Trim();
            if (value.Length is < 2 or > 12 || values.Any(existing => existing.Contains(value) || value.Contains(existing))) continue;
            values.Add(value);
            if (values.Count == 4) break;
        }
        return values;
    }

    [GeneratedRegex(@"(?:知识点|考点)\s*[:：]\s*([^\n；;]+)")]
    private static partial Regex ExplicitKnowledgeRegex();

    [GeneratedRegex(@"[\u4e00-\u9fff]{1,9}(?:病|炎|癌|瘤|症|中毒|衰竭|栓塞|血栓|缺氧|休克)")]
    private static partial Regex MedicalTermRegex();
}
