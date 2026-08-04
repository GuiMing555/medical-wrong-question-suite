using System.IO.Compression;
using System.Security;
using System.Text;

namespace WrongQuestionCapture.Windows;

internal sealed record DocxParagraph(
    string Text,
    bool Bold = false,
    bool Red = false,
    int FontSize = 22,
    bool PageBreakBefore = false,
    int SpaceAfter = 110);

internal static class MinimalDocxWriter
{
    public static void Write(string path, string title, IReadOnlyList<DocxParagraph> paragraphs)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        if (File.Exists(temporary)) File.Delete(temporary);
        using (var archive = ZipFile.Open(temporary, ZipArchiveMode.Create))
        {
            Add(archive, "[Content_Types].xml", ContentTypes);
            Add(archive, "_rels/.rels", PackageRelationships);
            Add(archive, "docProps/core.xml", CoreProperties(title));
            Add(archive, "word/document.xml", DocumentXml(paragraphs));
            Add(archive, "word/styles.xml", Styles);
            Add(archive, "word/_rels/document.xml.rels", DocumentRelationships);
        }
        File.Move(temporary, path, true);
    }

    private static void Add(ZipArchive archive, string name, string content)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(content);
    }

    private static string DocumentXml(IReadOnlyList<DocxParagraph> paragraphs)
    {
        var builder = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
        builder.Append("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>");
        foreach (var paragraph in paragraphs)
        {
            builder.Append("<w:p><w:pPr>");
            if (paragraph.PageBreakBefore) builder.Append("<w:pageBreakBefore/>");
            builder.Append($"<w:spacing w:after=\"{paragraph.SpaceAfter}\" w:line=\"360\" w:lineRule=\"auto\"/>");
            builder.Append("</w:pPr><w:r><w:rPr>");
            builder.Append("<w:rFonts w:ascii=\"Microsoft YaHei\" w:hAnsi=\"Microsoft YaHei\" w:eastAsia=\"微软雅黑\"/>");
            if (paragraph.Bold) builder.Append("<w:b/>");
            if (paragraph.Red) builder.Append("<w:color w:val=\"C62828\"/>");
            builder.Append($"<w:sz w:val=\"{paragraph.FontSize}\"/><w:szCs w:val=\"{paragraph.FontSize}\"/>");
            builder.Append("</w:rPr><w:t xml:space=\"preserve\">");
            builder.Append(SecurityElement.Escape(paragraph.Text) ?? string.Empty);
            builder.Append("</w:t></w:r></w:p>");
        }
        builder.Append("<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\" w:header=\"600\" w:footer=\"600\" w:gutter=\"0\"/></w:sectPr>");
        builder.Append("</w:body></w:document>");
        return builder.ToString();
    }

    private static string CoreProperties(string title) =>
        $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>{SecurityElement.Escape(title)}</dc:title><dc:creator>医学综合错题截图</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}</dcterms:created></cp:coreProperties>";

    private const string ContentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        </Types>
        """;

    private const string PackageRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>
        """;

    private const string DocumentRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """;

    private const string Styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/><w:qFormat/>
            <w:rPr><w:rFonts w:ascii="Microsoft YaHei" w:hAnsi="Microsoft YaHei" w:eastAsia="微软雅黑"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr>
          </w:style>
        </w:styles>
        """;
}
