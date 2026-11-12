using System.Globalization;
using Biblio.Core;

namespace Biblio.Views;

/// <summary>How "borrowed before" reads.</summary>
public static class BorrowedText
{
    /// <summary>A "YYYY-MM-DD" date in the given format ("MMM yyyy"), or null.</summary>
    private static string? Formatted(string? date, string format) =>
        date is { Length: >= 10 } && DateOnly.TryParseExact(date[..10], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
            ? d.ToString(format, CultureInfo.CurrentCulture)
            : null;

    /// <summary>"the audiobook", "on Blu-ray", "the book", or "as Kit".</summary>
    public static string BorrowedFormat(string code, LibraryInfo library)
    {
        var name = library.FormatName(code);
        return code switch
        {
            "AB" or "BOOK_CD" or "PLAYAWAY_AUDIOBOOK" => "the audiobook",
            "DVD" or "BLURAY" or "UK" or "DVD_PBLURAY" or "VIDEO_ONLINE" => $"on {name}",
            "BK" or "LPRINT" or "EBOOK" => $"the {name.ToLowerInvariant()}",
            _ => $"as {name}",
        };
    }

    /// <summary>For a row's tooltip: "Borrowed before · returned Mar 2024", or "Borrowed the audiobook · Mar 2024".</summary>
    public static string Short(BorrowedIndex.Match m, LibraryInfo library)
    {
        var when = Formatted(m.LastReturned ?? m.LastCheckout, "MMM yyyy");
        if (m.SameFormat)
        {
            var returned = m.LastReturned is not null ? "returned" : "borrowed";
            return when is null ? "Borrowed before" : $"Borrowed before · {returned} {when}";
        }
        var what = $"Borrowed {BorrowedFormat(m.Format, library)}";
        return when is null ? what : $"{what} · {when}";
    }

    /// <summary>For item detail: "You borrowed this in March 2024 · 3 times", or "You borrowed on DVD in March 2024".</summary>
    public static string Sentence(BorrowedIndex.Match m, LibraryInfo library)
    {
        var text = $"You borrowed {(m.SameFormat ? "this" : BorrowedFormat(m.Format, library))}";
        if (Formatted(m.LastCheckout ?? m.LastReturned, "MMMM yyyy") is { } when) text += $" in {when}";
        if (m.Count > 1) text += $" · {m.Count} times";
        return text;
    }
}
