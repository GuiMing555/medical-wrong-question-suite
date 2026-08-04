using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace WrongQuestionCapture.Windows;

internal sealed record CaptureResult(string FilePath, string Sha256, DateTimeOffset CapturedAt);

internal sealed class WindowCaptureService
{
    public CaptureResult Capture(WindowTarget target, string captureFolder)
    {
        if (!NativeMethods.IsWindow(target.Handle))
            throw new InvalidOperationException("目标窗口已关闭，请重新选定。");
        if (NativeMethods.IsIconic(target.Handle))
            throw new InvalidOperationException("目标窗口已最小化，请先恢复窗口。");

        var rectangle = GetWindowBounds(target.Handle);
        if (rectangle.Width < 100 || rectangle.Height < 100)
            throw new InvalidOperationException("目标窗口尺寸异常，无法截取。");

        Directory.CreateDirectory(captureFolder);
        using var bitmap = new Bitmap(rectangle.Width, rectangle.Height, PixelFormat.Format32bppArgb);
        var rendered = TryPrintWindow(target.Handle, bitmap);
        if (!rendered || LooksBlank(bitmap))
        {
            using var graphics = Graphics.FromImage(bitmap);
            graphics.CopyFromScreen(rectangle.Left, rectangle.Top, 0, 0, bitmap.Size, CopyPixelOperation.SourceCopy);
        }

        var capturedAt = DateTimeOffset.Now;
        var suffix = Guid.NewGuid().ToString("N")[..6];
        var path = Path.Combine(captureFolder, $"错题_{capturedAt:yyyyMMdd_HHmmss}_{suffix}.png");
        bitmap.Save(path, ImageFormat.Png);
        var hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
        return new CaptureResult(path, hash, capturedAt);
    }

    private static NativeMethods.Rect GetWindowBounds(IntPtr handle)
    {
        var status = NativeMethods.DwmGetWindowAttribute(
            handle,
            NativeMethods.DwmwaExtendedFrameBounds,
            out var rectangle,
            Marshal.SizeOf<NativeMethods.Rect>());
        if (status == 0) return rectangle;
        if (!NativeMethods.GetWindowRect(handle, out rectangle))
            throw new InvalidOperationException("无法读取目标窗口边界。");
        return rectangle;
    }

    private static bool TryPrintWindow(IntPtr handle, Bitmap bitmap)
    {
        using var graphics = Graphics.FromImage(bitmap);
        var deviceContext = graphics.GetHdc();
        try { return NativeMethods.PrintWindow(handle, deviceContext, NativeMethods.PwRenderFullContent); }
        finally { graphics.ReleaseHdc(deviceContext); }
    }

    private static bool LooksBlank(Bitmap bitmap)
    {
        var samplePoints = new[]
        {
            (bitmap.Width / 4, bitmap.Height / 4),
            (bitmap.Width / 2, bitmap.Height / 2),
            (bitmap.Width * 3 / 4, bitmap.Height * 3 / 4),
            (bitmap.Width / 3, bitmap.Height * 2 / 3)
        };
        var colors = samplePoints.Select(point => bitmap.GetPixel(point.Item1, point.Item2)).ToArray();
        var redRange = colors.Max(color => color.R) - colors.Min(color => color.R);
        var greenRange = colors.Max(color => color.G) - colors.Min(color => color.G);
        var blueRange = colors.Max(color => color.B) - colors.Min(color => color.B);
        return redRange <= 3 && greenRange <= 3 && blueRange <= 3;
    }
}
