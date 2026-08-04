using Windows.Graphics.Imaging;
using Windows.Globalization;
using Windows.Media.Ocr;
using Windows.Storage;

namespace WrongQuestionCapture.Windows;

internal sealed class WindowsOcrService
{
    public async Task<string> RecognizeAsync(string imagePath)
    {
        var chinese = new Language("zh-Hans");
        var engine = OcrEngine.IsLanguageSupported(chinese)
            ? OcrEngine.TryCreateFromLanguage(chinese)
            : OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine is null)
            throw new InvalidOperationException("Windows 未安装可用的本地 OCR 语言包。请在系统语言设置中安装中文（简体）文字识别。");
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(imagePath));
        using var stream = await file.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        var result = await engine.RecognizeAsync(bitmap);
        return string.Join(Environment.NewLine, result.Lines.Select(line => line.Text.Trim()).Where(line => line.Length > 0));
    }
}
