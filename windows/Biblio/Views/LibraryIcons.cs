using Biblio.Core;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Biblio.Views;

/// <summary>
/// Library icons from the core, cached on disk so each library's site is asked only once. A
/// wide directory logo is trimmed to its content. Used from the UI thread.
/// </summary>
internal static class LibraryIcons
{
    private static readonly Dictionary<string, Task<ImageSource?>> Loads = [];
    private static readonly string Cache =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Biblio", "LibraryIcons");

    /// <summary>Icons are keyed by website host, so a directory suggestion and the added library share one.</summary>
    public static string Key(string? website, string fallback) =>
        website is not null && Uri.TryCreate(website.Contains("://") ? website : $"https://{website}", UriKind.Absolute, out var uri)
            ? uri.Host.ToLowerInvariant() : fallback;

    /// <summary>The icon, or null if none was found (looked up again next launch). <paramref name="website"/>
    /// null reads it from <paramref name="subdomain"/>'s catalog.</summary>
    public static Task<ImageSource?> GetAsync(string key, string? website, string? subdomain = null, string? logo = null)
    {
        if (!Loads.TryGetValue(key, out var load)) Loads[key] = load = LoadAsync(key, website, subdomain, logo);
        return load;
    }

    private static async Task<ImageSource?> LoadAsync(string key, string? website, string? subdomain, string? logo)
    {
        var name = Uri.EscapeDataString(key);
        string square = Path.Combine(Cache, name + ".icon"), wide = Path.Combine(Cache, name + ".logo");
        try
        {
            if (File.Exists(square)) return await Decode(await File.ReadAllBytesAsync(square), false);
            if (File.Exists(wide)) return await Decode(await File.ReadAllBytesAsync(wide), true);
            if (await Task.Run(() => Interop.LibraryIcon(website, subdomain, logo)) is not { } found) return null;
            var source = await Decode(found.Bytes, found.IsLogo);
            Directory.CreateDirectory(Cache);
            await File.WriteAllBytesAsync(found.IsLogo ? wide : square, found.Bytes);
            return source;
        }
        catch (Exception) { return null; }
    }

    private static async Task<ImageSource> Decode(byte[] bytes, bool isLogo)
    {
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(bytes.AsBuffer());
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var transform = new BitmapTransform();
        if (isLogo)
        {
            var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new BitmapTransform(),
                ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            int w = (int)decoder.PixelWidth, h = (int)decoder.PixelHeight;
            if (Interop.LogoBounds(data.DetachPixelData(), w, h, w * 4, 4) is { } b)
                transform.Bounds = new BitmapBounds { X = (uint)b[0], Y = (uint)b[1], Width = (uint)b[2], Height = (uint)b[3] };
        }
        var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
            ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        var source = new SoftwareBitmapSource();
        await source.SetBitmapAsync(bitmap);
        return source;
    }
}
