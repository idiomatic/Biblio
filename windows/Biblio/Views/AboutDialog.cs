using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Biblio.Views;

/// <summary>The About box, opened from the version at the foot of the sidebar.</summary>
public static class AboutDialog
{
    /// <summary>The app version, "1.8".</summary>
    public static string Version =>
        typeof(AboutDialog).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}" : "?";

    public const string Credits = "Biblio was made by people working together with AI assistants. They shared the work of planning, building, and testing the app.";
    public const string Independence = "Biblio is an independent app. It isn’t made by BiblioCommons or by your library.";

    public static async Task Show(XamlRoot root)
    {
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var copy = new Button { Content = "Copy Diagnostic Log", HorizontalAlignment = HorizontalAlignment.Center };
        copy.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(DiagnosticLog.Report());
            Clipboard.SetContent(package);
            copy.Content = "Copied";
        };
        TextBlock Text(string text, Brush? brush = null, string style = "BodyTextBlockStyle")
        {
            var t = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Style = (Style)Application.Current.Resources[style] };
            if (brush is not null) t.Foreground = brush;
            return t;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = root, CloseButtonText = "Close", DefaultButton = ContentDialogButton.Close,
            Content = new StackPanel
            {
                Spacing = 12, MaxWidth = 420,
                Children =
                {
                    Text("Biblio", style: "SubtitleTextBlockStyle"),
                    Text($"Version {Version}", secondary),
                    Text(Credits),
                    Text(Independence, secondary),
                    copy,
                    Text("A list of the times a library’s server limited or failed a request. It names no account, and nothing is sent unless you share it.",
                        secondary, "CaptionTextBlockStyle"),
                },
            },
        };
        await dialog.ShowAsync();
    }
}

/// <summary>
/// Servers answering 429 or 5xx, as libbiblio saw them, kept across launches in local app data so a
/// report can show how often it happens. Nothing is sent anywhere; About's Copy Diagnostic Log copies
/// it. Entries carry the masked path and timing, never an account. Used from the UI thread.
/// </summary>
public static class DiagnosticLog
{
    private const int MaxEntries = 50;
    private static readonly string Path = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Biblio", "diagnostics.json");
    /// <summary>The core's running total when this launch last merged, so only new incidents count.</summary>
    private static long _seenTotal;

    /// <summary>Adds this launch's new incidents to the saved log.</summary>
    public static void Sync()
    {
        try
        {
            var current = JsonNode.Parse(Core.Core.Incidents()) as JsonObject;
            var total = current?["total"]?.GetValue<long>() ?? 0;
            if (total <= _seenTotal) return;
            var saved = Load();
            saved["total"] = (saved["total"]?.GetValue<long>() ?? 0) + total - _seenTotal;
            _seenTotal = total;
            var entries = saved["recent"] as JsonArray ?? new JsonArray();
            static string Key(JsonNode? e) => $"{e?["at"]}|{e?["status"]}|{e?["path"]}";
            var known = entries.Select(Key).ToHashSet();
            foreach (var e in current?["recent"] as JsonArray ?? new JsonArray())
                if (known.Add(Key(e))) entries.Add(e?.DeepClone());
            while (entries.Count > MaxEntries) entries.RemoveAt(0);
            saved["recent"] = entries.DeepClone();
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            File.WriteAllText(Path, saved.ToJsonString());
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or InvalidOperationException) { }
    }

    /// <summary>A JSON report: the app version, how many times in all, and the latest entries.</summary>
    public static string Report()
    {
        Sync();
        var saved = Load();
        var report = new JsonObject
        {
            ["app"] = $"Biblio {AboutDialog.Version} (Windows)",
            ["total"] = saved["total"]?.GetValue<long>() ?? 0,
            ["recent"] = saved["recent"]?.DeepClone() ?? new JsonArray(),
        };
        return report.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    private static JsonObject Load()
    {
        try { return File.Exists(Path) && JsonNode.Parse(File.ReadAllText(Path)) is JsonObject o ? o : new JsonObject(); }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException) { return new JsonObject(); }
    }
}
