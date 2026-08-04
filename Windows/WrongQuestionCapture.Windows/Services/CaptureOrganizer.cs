using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MedicalQuestionSuite.Core;

namespace WrongQuestionCapture.Windows;

internal sealed record OrganizeReport(
    int NewImages,
    int TotalImages,
    int UniqueQuestions,
    int ConsecutiveDuplicates,
    int RepeatedQuestions,
    int ReviewImages,
    int InsertedQuestions,
    int UpdatedQuestions,
    int UnchangedQuestions,
    IReadOnlyList<string> SyncFailures,
    string OutputFolder)
{
    public string ShortSummary => $"新增 {NewImages} 张，待校对 {ReviewImages} 张，题库新增 {InsertedQuestions} 题。";
    public string Summary =>
        $"新增 {NewImages} 张，累计 {TotalImages} 张；查重后 {UniqueQuestions} 题，" +
        $"忽略 {ConsecutiveDuplicates} 个连续截图误操作，{RepeatedQuestions} 题非连续重复出现；" +
        $"待校对 {ReviewImages} 张。\n" +
        $"共享题库：新增 {InsertedQuestions}，更新 {UpdatedQuestions}，幂等跳过 {UnchangedQuestions}" +
        (SyncFailures.Count == 0 ? "。" : $"，失败 {SyncFailures.Count}：{string.Join("；", SyncFailures.Take(3))}") +
        $"\n已生成纯题、答案与解析、薄弱知识点三份文档：{OutputFolder}";
}

internal sealed class CaptureOrganizer : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = false
    };

    private readonly SettingsStore _settingsStore;
    private readonly WindowsOcrService _ocr;
    private readonly QuestionTextParser _parser = new();
    private readonly QuestionBankStore _questionBank;
    private readonly SharedChangeNotifier _changeNotifier;
    private readonly SemaphoreSlim _organizeLock = new(1, 1);

    public CaptureOrganizer(
        SettingsStore settingsStore,
        WindowsOcrService ocr,
        QuestionBankStore questionBank,
        SharedChangeNotifier changeNotifier)
    {
        _settingsStore = settingsStore;
        _ocr = ocr;
        _questionBank = questionBank;
        _changeNotifier = changeNotifier;
    }

    public async Task<OrganizeReport> OrganizeAsync()
    {
        await _organizeLock.WaitAsync();
        try
        {
            var settings = _settingsStore.Load();
            settings.ValidateAndCreateFolders();
            var statePath = Path.Combine(settings.OutputFolderPath, ".capture-state.windows.json");
            var state = await LoadStateAsync(statePath);
            var knownHashes = state.Items.Select(item => item.SourceHash).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var images = DiscoverImages(settings.CaptureFolderPath, settings.OutputFolderPath);
            var nextNumber = state.Items.Select(item => ParseItemNumber(item.Id)).DefaultIfEmpty(0).Max() + 1;
            var newCount = 0;

            foreach (var path in images)
            {
                var hash = await HashFileAsync(path);
                if (knownHashes.Contains(hash)) continue;
                var capturedAt = File.GetCreationTime(path);
                var record = await RecognizeRecordAsync(path, hash, new DateTimeOffset(capturedAt), nextNumber++);
                state.Items.Add(record);
                knownHashes.Add(hash);
                newCount++;
            }

            state.Items = state.Items.OrderBy(item => item.CapturedAt).ThenBy(item => item.Id, StringComparer.Ordinal).ToList();
            state.LastRunAt = DateTimeOffset.Now;
            await SaveStateAsync(statePath, state);

            var deduplication = Deduplicate(state.Items);
            var inserted = 0;
            var updated = 0;
            var unchanged = 0;
            var syncFailures = new List<string>();
            var notified = false;
            foreach (var record in state.Items.Where(item => !item.NeedsReview))
            {
                try
                {
                    var stableExternalId = deduplication.StableExternalIdBySourceHash[record.SourceHash];
                    var result = _questionBank.ImportCapturedQuestion(ToDraft(record, stableExternalId), markWrong: true);
                    switch (result.Status)
                    {
                        case QuestionImportStatus.Inserted: inserted++; notified = true; break;
                        case QuestionImportStatus.Updated: updated++; notified = true; break;
                        case QuestionImportStatus.Unchanged: unchanged++; break;
                    }
                }
                catch (Exception ex)
                {
                    syncFailures.Add($"{Path.GetFileName(record.SourcePath)}：{ex.Message}");
                }
            }
            if (notified) _changeNotifier.Notify();

            // 共享题库是截图后即时联动的权威状态。先完成数据库事务，
            // 再替换可能被 Word 占用的文档，避免文件锁导致新错题未入库。
            SynchronizeReviewImages(settings.CaptureFolderPath, state.Items, deduplication.ConsecutiveDuplicates);
            DocumentSetWriter.Write(settings.OutputFolderPath, deduplication);

            return new OrganizeReport(
                newCount,
                state.Items.Count,
                deduplication.UniqueItems.Count,
                deduplication.ConsecutiveDuplicates.Count,
                deduplication.OccurrenceCountsByPrimaryId.Values.Count(value => value >= 2),
                state.Items.Count(item => item.NeedsReview),
                inserted,
                updated,
                unchanged,
                syncFailures,
                settings.OutputFolderPath);
        }
        finally
        {
            _organizeLock.Release();
        }
    }

    private async Task<CapturedRecord> RecognizeRecordAsync(string path, string hash, DateTimeOffset capturedAt, int number)
    {
        try
        {
            var rawText = await _ocr.RecognizeAsync(path);
            var parsed = _parser.Parse(rawText);
            return new CapturedRecord
            {
                Id = $"WQ{number:000000}",
                SourcePath = Path.GetFullPath(path),
                SourceHash = hash,
                CapturedAt = capturedAt,
                RecognizedAt = DateTimeOffset.Now,
                RawText = rawText,
                Stem = parsed.Stem,
                Options = parsed.Options.ToList(),
                CorrectLabels = parsed.CorrectLabels.ToHashSet(StringComparer.Ordinal),
                Explanation = parsed.Explanation,
                KnowledgePoints = parsed.KnowledgePoints.ToList(),
                Issues = parsed.Issues.ToList()
            };
        }
        catch (Exception ex)
        {
            return new CapturedRecord
            {
                Id = $"WQ{number:000000}",
                SourcePath = Path.GetFullPath(path),
                SourceHash = hash,
                CapturedAt = capturedAt,
                RecognizedAt = DateTimeOffset.Now,
                RawText = "[OCR 失败] " + ex.Message,
                Stem = "[OCR 失败，请对照原图校对]",
                Issues = ["OCR待校对"]
            };
        }
    }

    private static CapturedQuestionDraft ToDraft(CapturedRecord record, string stableExternalId) => new(
        stableExternalId,
        record.Stem,
        record.Options.Select(option => new CapturedQuestionOption(option.Label, option.Text)).ToArray(),
        record.CorrectLabels,
        record.Explanation,
        record.KnowledgePoints,
        record.SourcePath,
        record.SourceHash,
        record.CapturedAt,
        "capture-windows");

    private static string StableExternalId(string stem)
    {
        var normalized = string.Concat(stem.ToLowerInvariant().Where(char.IsLetterOrDigit));
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return "capture:" + Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static IReadOnlyList<string> DiscoverImages(string captureRoot, string outputRoot)
    {
        var output = Path.GetFullPath(outputRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var extensions = new HashSet<string>([".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"], StringComparer.OrdinalIgnoreCase);
        return Directory.EnumerateFiles(captureRoot, "*", SearchOption.AllDirectories)
            .Where(path => extensions.Contains(Path.GetExtension(path)))
            .Where(path => !Path.GetFullPath(path).StartsWith(output, StringComparison.OrdinalIgnoreCase))
            .Where(path => !Path.GetFullPath(path).Contains(Path.DirectorySeparatorChar + "待人工校对图片" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static async Task<string> HashFileAsync(string path)
    {
        await using var stream = File.OpenRead(path);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream)).ToLowerInvariant();
    }

    private static int ParseItemNumber(string id) =>
        id.StartsWith("WQ", StringComparison.Ordinal) && int.TryParse(id[2..], out var value) ? value : 0;

    private static async Task<CaptureState> LoadStateAsync(string path)
    {
        if (!File.Exists(path)) return new CaptureState();
        try
        {
            await using var stream = File.OpenRead(path);
            var state = await JsonSerializer.DeserializeAsync<CaptureState>(stream, JsonOptions);
            return state?.SchemaVersion == 1 ? state : new CaptureState();
        }
        catch (JsonException)
        {
            var backup = path + ".invalid-" + DateTime.Now.ToString("yyyyMMdd-HHmmss");
            File.Copy(path, backup, true);
            return new CaptureState();
        }
    }

    private static async Task SaveStateAsync(string path, CaptureState state)
    {
        var temporary = path + ".tmp";
        await using (var stream = File.Create(temporary))
            await JsonSerializer.SerializeAsync(stream, state, JsonOptions);
        File.Move(temporary, path, true);
    }

    private static void SynchronizeReviewImages(
        string captureRoot,
        IReadOnlyList<CapturedRecord> allItems,
        IReadOnlyList<CapturedRecord> consecutiveDuplicates)
    {
        var folder = Path.Combine(captureRoot, "待人工校对图片");
        Directory.CreateDirectory(folder);
        var duplicateHashes = consecutiveDuplicates.Select(item => item.SourceHash).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var item in allItems.Where(item => item.NeedsReview || duplicateHashes.Contains(item.SourceHash)))
        {
            var issues = new List<string>();
            if (duplicateHashes.Contains(item.SourceHash)) issues.Add("重复截图");
            issues.AddRange(item.Issues);
            var prefix = string.Join("_", issues.Distinct(StringComparer.Ordinal));
            var destination = Path.Combine(folder, $"{prefix}_{item.Id}_{Path.GetFileName(item.SourcePath)}");
            if (!File.Exists(destination)) File.Copy(item.SourcePath, destination);
        }
    }

    public void Dispose()
    {
        _questionBank.Dispose();
        _organizeLock.Dispose();
    }

    internal sealed record DeduplicationResult(
        IReadOnlyList<CapturedRecord> UniqueItems,
        IReadOnlyList<CapturedRecord> EpisodeItems,
        IReadOnlyList<CapturedRecord> ConsecutiveDuplicates,
        IReadOnlyDictionary<string, int> OccurrenceCountsByPrimaryId,
        IReadOnlyDictionary<string, string> StableExternalIdBySourceHash);

    private static DeduplicationResult Deduplicate(IReadOnlyList<CapturedRecord> records)
    {
        var primaryByKey = new Dictionary<string, CapturedRecord>(StringComparer.Ordinal);
        var unique = new List<CapturedRecord>();
        var episodes = new List<CapturedRecord>();
        var consecutive = new List<CapturedRecord>();
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        var externalIds = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? previousKey = null;

        foreach (var record in records)
        {
            var rawKey = DuplicateKey(record);
            var key = FindEquivalentKey(rawKey, primaryByKey.Keys) ?? rawKey;
            if (!primaryByKey.TryGetValue(key, out var primary))
            {
                primaryByKey[key] = record;
                unique.Add(record);
                episodes.Add(record);
                counts[record.Id] = 1;
            }
            else if (key == previousKey)
            {
                consecutive.Add(record);
            }
            else
            {
                episodes.Add(record);
                counts[primary.Id]++;
            }
            externalIds[record.SourceHash] = StableExternalId(primaryByKey[key].Stem);
            previousKey = key;
        }
        return new DeduplicationResult(unique, episodes, consecutive, counts, externalIds);
    }

    private static string? FindEquivalentKey(string candidate, IEnumerable<string> existingKeys)
    {
        if (candidate.StartsWith("unreadable:", StringComparison.Ordinal)) return null;
        foreach (var existing in existingKeys)
        {
            if (Math.Abs(existing.Length - candidate.Length) > Math.Max(3, candidate.Length / 12)) continue;
            var shorter = Math.Min(existing.Length, candidate.Length);
            if (shorter >= 12 && (existing.Contains(candidate, StringComparison.Ordinal) || candidate.Contains(existing, StringComparison.Ordinal)))
                return existing;
            var allowedDistance = Math.Max(1, shorter / 20);
            if (EditDistanceAtMost(existing, candidate, allowedDistance)) return existing;
        }
        return null;
    }

    private static bool EditDistanceAtMost(string left, string right, int maximum)
    {
        if (Math.Abs(left.Length - right.Length) > maximum) return false;
        var previous = Enumerable.Range(0, right.Length + 1).ToArray();
        var current = new int[right.Length + 1];
        for (var row = 1; row <= left.Length; row++)
        {
            current[0] = row;
            var rowMinimum = current[0];
            for (var column = 1; column <= right.Length; column++)
            {
                var cost = left[row - 1] == right[column - 1] ? 0 : 1;
                current[column] = Math.Min(Math.Min(current[column - 1] + 1, previous[column] + 1), previous[column - 1] + cost);
                rowMinimum = Math.Min(rowMinimum, current[column]);
            }
            if (rowMinimum > maximum) return false;
            (previous, current) = (current, previous);
        }
        return previous[right.Length] <= maximum;
    }

    private static string DuplicateKey(CapturedRecord record)
    {
        if (record.Stem.StartsWith("[OCR", StringComparison.Ordinal)) return "unreadable:" + record.SourceHash;
        var key = string.Concat(record.Stem.ToLowerInvariant().Where(char.IsLetterOrDigit));
        return key.Length == 0 ? "unreadable:" + record.SourceHash : key;
    }
}
