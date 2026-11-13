namespace Biblio.Core;

// The data every Biblio app shows, as libbiblio returns it (core/src/models.zig), built from its
// C structs in Interop.cs.

/// <summary>A catalog record. Format may refine LibraryFormat, the library's own code (4K filed as Blu-ray).</summary>
public sealed record Bib(
    string Id, string Title, string? Subtitle, List<string>? Authors, string Format, string? PublicationDate,
    string? Edition, string? CallNumber, string? Summary, string? JacketSmall, string? JacketLarge,
    string MaterialType, bool Holdable, string? Status, int HeldCopies, int AvailableCopies, int TotalCopies, int OnOrderCopies,
    string LibraryFormat)
{
    public string? PrimaryAuthor => Authors is { Count: > 0 } a ? a[0] : null;

    /// <summary>"2019" from "c2019.", "[2019?]", or "20190312"; else the date as given.</summary>
    public string? Year => Core.Year(PublicationDate);
}

public sealed record Hold(string Id, string MetadataId, string Status, int? Position, string? PickupLocation,
    string? ExpiryDate, string? PickupByDate, string? SuspendEndDate, bool CanCancel)
{
    public HoldRank Rank => Core.HoldStatusRank(Status);
    public bool IsReady => Rank == HoldRank.Ready;
    /// <summary>"Ready for pickup", "In transit", "On hold", or "Paused".</summary>
    public string StatusName => Core.HoldStatusName(Status);
}

public sealed record Checkout(string Id, string MetadataId, string? Status, string? DueDate, string? CheckoutDate, int? TimesRenewed);
public sealed record HistoryEntry(string Id, string MetadataId, string? CheckoutDate, string? ReturnedDate);

/// <summary>The account's relationship to an item; Kind is "onHold" or "checkedOut".</summary>
public sealed record AccountStatus(string Kind, bool Ready, int? Position, string? Due);

public sealed record ListEntry(string Id, Bib Bib, string Kind, int ServerIndex, Hold? Hold, Checkout? Checkout,
    HistoryEntry? History, AccountStatus? AccountStatus);

public sealed record FacetValue(string Value, int Count);
public sealed record Facet(string Id, List<FacetValue> Values);

public sealed record ListPage(List<ListEntry> Entries, int Page, int Pages, int Count, int PageSize,
    List<Facet>? Facets, List<string>? SortOptions, string? AppliedSort);

public sealed record CopyAvailability(string Id, string Branch, string Status, bool IsAvailable, string? Collection,
    string? CallNumber, string? DueDate, bool IsOnOrder, string Kind);

/// <summary>A record field; IsEdition marks the one that states the edition.</summary>
public sealed record DetailField(string Label, List<string> Values, bool IsEdition = false);
public sealed record Location(string Id, string Name);

public sealed record Patron(long UserId, long AccountId, string Name, string? Email, string Language, string? Barcode,
    string? PreferredPickup, bool? BorrowingHistoryEnabled, string? FirstName = null);

/// <summary>The account's settings as the library has them now (biblio_account_settings).</summary>
public sealed record AccountSettings(string? Email, string? Pickup, string? Language);

public sealed record LibraryInfo(string Subdomain, string Name, string? ShortName, string? PrimaryColor, string? Website,
    Dictionary<string, string>? Labels, List<string>? Languages, List<string>? Users)
{
    public string DisplayName => ShortName ?? Name;

    public string FormatName(string code) => Core.FormatName(code, Labels);

    public string SortName(string id) => Core.SortName(id, Labels);
}

public sealed record DirectoryEntry(string Name, string? Website, string? Region, string? Logo);
public sealed record DirectoryPage(List<DirectoryEntry> Entries, string? Next);
public sealed record Refusal(string HoldId, string Reason);
