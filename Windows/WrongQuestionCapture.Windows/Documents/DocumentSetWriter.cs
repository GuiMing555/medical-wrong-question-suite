namespace WrongQuestionCapture.Windows;

internal static class DocumentSetWriter
{
    public static void Write(string outputFolder, CaptureOrganizer.DeduplicationResult result)
    {
        Directory.CreateDirectory(outputFolder);
        MinimalDocxWriter.Write(
            Path.Combine(outputFolder, "医学综合错题本_纯题.docx"),
            "医学综合错题本_纯题",
            QuestionParagraphs(result));
        MinimalDocxWriter.Write(
            Path.Combine(outputFolder, "医学综合错题本_答案与解析.docx"),
            "医学综合错题本_答案与解析",
            AnswerParagraphs(result));
        MinimalDocxWriter.Write(
            Path.Combine(outputFolder, "医学综合错题本_薄弱知识点.docx"),
            "医学综合错题本_薄弱知识点",
            KnowledgeParagraphs(result));
    }

    private static IReadOnlyList<DocxParagraph> QuestionParagraphs(CaptureOrganizer.DeduplicationResult result)
    {
        var paragraphs = Cover("医学综合错题本", "纯题版 · 截图即收录", result.UniqueItems.Count,
            "本册不含答案与解析。页面中已答对的截图也视为需要复习。");
        foreach (var item in result.UniqueItems)
        {
            var count = result.OccurrenceCountsByPrimaryId.GetValueOrDefault(item.Id, 1);
            paragraphs.Add(new DocxParagraph($"{item.Id}    {item.CapturedAt:yyyy-MM-dd}", true, false, 26, false, 70));
            if (count >= 2) paragraphs.Add(new DocxParagraph($"重复出现 {count} 次 · 仍未掌握", true, true, 22));
            paragraphs.Add(new DocxParagraph(item.Stem, true, false, 24));
            if (item.Options.Count == 0)
                paragraphs.Add(new DocxParagraph("选项待人工校对，请对照原截图。", false, true));
            else
                foreach (var option in item.Options) paragraphs.Add(new DocxParagraph($"{option.Label}. {option.Text}", false, false, 22, false, 60));
            paragraphs.Add(new DocxParagraph("作答：________________________________", false, false, 22, false, 220));
        }
        return paragraphs;
    }

    private static IReadOnlyList<DocxParagraph> AnswerParagraphs(CaptureOrganizer.DeduplicationResult result)
    {
        var paragraphs = Cover("医学综合错题本", "答案与解析", result.UniqueItems.Count,
            "本册与纯题版题号对应。缺项项目会明确标注，不猜测答案或解析。");
        foreach (var item in result.UniqueItems)
        {
            var count = result.OccurrenceCountsByPrimaryId.GetValueOrDefault(item.Id, 1);
            paragraphs.Add(new DocxParagraph($"{item.Id}    {item.CapturedAt:yyyy-MM-dd}", true, false, 26, false, 70));
            if (count >= 2) paragraphs.Add(new DocxParagraph($"重复出现 {count} 次 · 仍未掌握", true, true));
            paragraphs.Add(new DocxParagraph(item.Stem, true, false, 24));
            var answer = item.CorrectLabels.Count == 0 ? "待人工校对" : string.Join("、", item.CorrectLabels.OrderBy(value => value, StringComparer.Ordinal));
            paragraphs.Add(new DocxParagraph("参考答案：" + answer, true));
            paragraphs.Add(new DocxParagraph("参考解析：" + (string.IsNullOrWhiteSpace(item.Explanation) ? "待人工校对" : item.Explanation)));
            if (item.NeedsReview) paragraphs.Add(new DocxParagraph("待校对：" + string.Join("、", item.Issues), true, true));
            paragraphs.Add(new DocxParagraph("原截图：" + item.SourcePath, false, false, 18, false, 220));
        }
        return paragraphs;
    }

    private static IReadOnlyList<DocxParagraph> KnowledgeParagraphs(CaptureOrganizer.DeduplicationResult result)
    {
        var occurrenceCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        var itemIds = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        foreach (var item in result.EpisodeItems)
        {
            foreach (var point in item.KnowledgePoints.Distinct(StringComparer.Ordinal))
            {
                occurrenceCounts[point] = occurrenceCounts.GetValueOrDefault(point) + 1;
                if (!itemIds.TryGetValue(point, out var ids)) itemIds[point] = ids = new HashSet<string>(StringComparer.Ordinal);
                ids.Add(item.Id);
            }
        }

        var paragraphs = Cover("医学综合错题本", "薄弱知识点", occurrenceCounts.Count,
            "知识点只从当前题干和解析的已识别文字中提取。非连续出现两次或以上时标红。");
        paragraphs.Add(new DocxParagraph("重点巩固：出现两次或以上", true, false, 28));
        var repeated = occurrenceCounts.Where(pair => pair.Value >= 2).OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key, StringComparer.Ordinal).ToArray();
        if (repeated.Length == 0) paragraphs.Add(new DocxParagraph("当前没有重复出现的知识点。"));
        foreach (var pair in repeated)
        {
            var related = string.Join("、", itemIds[pair.Key].OrderBy(value => value, StringComparer.Ordinal));
            paragraphs.Add(new DocxParagraph($"{pair.Key}    累计 {pair.Value} 次 · 仍未掌握    关联：{related}", true, true));
        }

        paragraphs.Add(new DocxParagraph("待巩固：出现一次", true, false, 28, false, 120));
        foreach (var pair in occurrenceCounts.Where(pair => pair.Value == 1).OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            var related = string.Join("、", itemIds[pair.Key].OrderBy(value => value, StringComparer.Ordinal));
            paragraphs.Add(new DocxParagraph($"{pair.Key}    关联：{related}"));
        }

        var missing = result.UniqueItems.Where(item => item.KnowledgePoints.Count == 0).Select(item => item.Id).ToArray();
        if (missing.Length > 0)
        {
            paragraphs.Add(new DocxParagraph("待人工补充", true, false, 28));
            paragraphs.Add(new DocxParagraph("以下题目未能从现有文字中可靠提取知识点：" + string.Join("、", missing), false, true));
        }
        return paragraphs;
    }

    private static List<DocxParagraph> Cover(string title, string subtitle, int itemCount, string note) =>
    [
        new(title, true, false, 42, false, 180),
        new(subtitle, true, false, 30, false, 160),
        new($"当前收录：{itemCount}    生成时间：{DateTime.Now:yyyy-MM-dd HH:mm}", false, false, 22, false, 120),
        new(note, false, false, 20, false, 260),
        new("成人高考专升本 · 医学综合", false, false, 18, true, 140)
    ];
}
