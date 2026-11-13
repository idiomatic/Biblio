using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Biblio.Views;

/// <summary>
/// Icon glyphs, in Segoe Fluent Icons on Windows 11 and Segoe MDL2 Assets on Windows 10: every glyph
/// here has the same code point in both.
/// </summary>
public static class Icons
{
    public static readonly FontFamily Font = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    public const string History = "";
    public const string CheckMark = "";
    public const string Package = "";
    public const string Recent = "";
    public const string Contact = "";
    public const string Switch = "";
    public const string Repair = "";
    public const string Unknown = "";
    public const string Home = "";
    public const string Cancel = "";
    public const string Info = "";
    public const string Filter = "";
    public const string Copy = "";

    /// <summary>Multi-select (E762).</summary>
    public const string MultiSelect = "";

    public static FontIcon Make(string glyph, double size = 14, Brush? foreground = null)
    {
        var icon = new FontIcon { Glyph = glyph, FontFamily = Font, FontSize = size, VerticalAlignment = VerticalAlignment.Center };
        if (foreground is not null) icon.Foreground = foreground;
        return icon;
    }

    /// <summary>A copy status's glyph (biblio_copy_t.kind).</summary>
    public static string ForCopy(string kind) => kind switch
    {
        "available" => CheckMark,
        "onOrder" => Package,
        "out" => Recent,
        "held" => Contact,
        "transit" => Switch,
        "repair" => Repair,
        "missing" or "claimsReturned" => Unknown,
        "libraryUseOnly" => Home,
        "withdrawn" => Cancel,
        _ => Info,
    };
}

/// <summary>
/// Status colors, adjusted by the core (biblio_readable_tint) to 4.5:1 contrast on the light or dark
/// theme's background; the status is always written out too.
/// </summary>
public static class StatusBrushes
{
    private static readonly Dictionary<(string, bool), Brush> Cache = [];

    private static string Hex(string kind) => kind switch
    {
        "available" => "#107C10",
        "onOrder" => "#00786E",
        "out" or "other" => "#9D5D00",
        "held" => "#7636A0",
        "transit" => "#005A9E",
        "repair" => "#795548",
        "missing" or "claimsReturned" => "#C42B1C",
        _ => "#707070",
    };

    /// <summary>A copy status's color (biblio_copy_t.kind), for the theme in use.</summary>
    public static Brush Copy(string kind, bool dark)
    {
        var hex = Hex(kind);
        if (Cache.TryGetValue((hex, dark), out var brush)) return brush;
        var tint = Core.Core.ReadableTint(hex, dark) ?? hex;
        var color = Microsoft.UI.ColorHelper.FromArgb(255,
            System.Convert.ToByte(tint.Substring(1, 2), 16), System.Convert.ToByte(tint.Substring(3, 2), 16),
            System.Convert.ToByte(tint.Substring(5, 2), 16));
        return Cache[(hex, dark)] = new SolidColorBrush(color);
    }

    public static Brush Availability(string? status, bool dark) => Copy(status switch
    {
        "AVAILABLE" => "available",
        "ON_ORDER" => "onOrder",
        "UNAVAILABLE" or "NOT_AVAILABLE" => "out",
        _ => "withdrawn",
    }, dark);
}

/// <summary>How an item reads, the same in list rows and item detail.</summary>
public static class ItemText
{
    /// <summary>Format, year, and edition, as present.</summary>
    public static List<string> Details(Bib bib, LibraryInfo library, string? edition = null) =>
        new[] { library.FormatName(bib.Format), bib.Year, edition ?? bib.Edition }.Where(s => !string.IsNullOrEmpty(s)).Select(s => s!).ToList();

    /// <summary>
    /// The availability line: status, copies on order (a box), people waiting, and copies. A history
    /// row says when it was returned instead.
    /// </summary>
    public static UIElement? Availability(ListEntry entry, bool dark)
    {
        // The text wraps in the room there is; the on-order copies keep their own column.
        var line = new Grid { ColumnSpacing = 4, ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        if (entry.History is { } h)
        {
            if (h.ReturnedDate is not { } r) return null;
            line.Children.Add(new TextBlock { Text = $"Returned {r}", Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
            return line;
        }
        var b = entry.Bib;
        var brush = StatusBrushes.Availability(b.Status, dark);
        string? label = b.Status switch { "AVAILABLE" => "Available", "ON_ORDER" => "On order", "UNAVAILABLE" or "NOT_AVAILABLE" => "All copies in use", _ => null };
        var parts = new List<string>();
        if (label is not null) parts.Add(label);
        if (b.HeldCopies > 0) parts.Add(b.HeldCopies == 1 ? "1 person waiting" : $"{b.HeldCopies:N0} people waiting");
        if (b.TotalCopies > 0) parts.Add(b.TotalCopies == 1 ? "1 copy" : $"{b.TotalCopies:N0} copies");
        if (parts.Count > 0) line.Children.Add(new TextBlock { Text = string.Join(" · ", parts), Foreground = brush, TextWrapping = TextWrapping.Wrap });
        // Copies the library has ordered but not received, beside the ones it has.
        if (b.OnOrderCopies > 0 && b.Status != "ON_ORDER")
        {
            var onOrder = StatusBrushes.Copy("onOrder", dark);
            var box = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            if (parts.Count > 0) box.Children.Add(new TextBlock { Text = "·", Foreground = brush });
            box.Children.Add(Icons.Make(Icons.Package, 12, onOrder));
            box.Children.Add(new TextBlock { Text = $"{b.OnOrderCopies:N0} on order", Foreground = onOrder });
            Grid.SetColumn(box, 1);
            line.Children.Add(box);
        }
        return line.Children.Count > 0 ? line : null;
    }

    /// <summary>
    /// The account's relationship to the item, as one colored capsule: ready for pickup (by a date), in
    /// transit, paused, or on hold, with the place in line; or checked out and due. Null if none.
    /// </summary>
    public static UIElement? Relationship(ListEntry entry, bool dark)
    {
        string text;
        string kind;
        if (entry.Hold is { } hold)
        {
            var rank = hold.Rank;
            text = hold.StatusName;
            if (rank == HoldRank.Ready && hold.PickupByDate is { } by) text += $" by {by}";
            else if (hold.Position is { } p) text += $" · #{p:N0}";
            kind = rank switch { HoldRank.Ready => "available", HoldRank.InTransit => "onOrder", HoldRank.Paused => "withdrawn", _ => "transit" };
        }
        else if (entry.Checkout is not null || entry.AccountStatus?.Kind == "checkedOut")
        {
            var due = entry.Checkout?.DueDate ?? entry.AccountStatus?.Due;
            text = due is null ? "Checked out" : $"Checked out · due {due}";
            kind = "held";
        }
        else if (entry.AccountStatus is { } s && entry.History is null)
        {
            text = s.Ready ? "Ready for pickup" : s.Position is { } p ? $"On hold · #{p:N0}" : "On hold";
            kind = s.Ready ? "available" : "transit";
        }
        else return null;
        var brush = StatusBrushes.Copy(kind, dark);
        var tint = ((SolidColorBrush)brush).Color;
        tint.A = 0x24;
        return new Border
        {
            CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 1, 8, 2), HorizontalAlignment = HorizontalAlignment.Left,
            Background = new SolidColorBrush(tint),
            Child = new TextBlock { Text = text, Foreground = brush, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] },
        };
    }

    /// <summary>"NONFICTION" as "Nonfiction", "PAST_WEEK" as "Past week".</summary>
    public static string Prettified(string value)
    {
        var s = value.Replace('_', ' ').ToLowerInvariant();
        return s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];
    }
}
