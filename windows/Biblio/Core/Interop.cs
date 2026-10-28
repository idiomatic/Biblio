using System.Runtime.InteropServices;

namespace Biblio.Core;

/// <summary>
/// libbiblio's typed interface (core/include/biblio.h): the C structs, mirrored field for field
/// as blittable structs, and calls that convert each result into the app's records and free it.
/// Every call here blocks; CoreClient and Core run them on the thread pool.
/// </summary>
internal static unsafe class Interop
{
    private const string Lib = "biblio.dll";

    // MARK: C structs (keep in step with biblio.h)

    [StructLayout(LayoutKind.Sequential)] public struct Error { public int Kind; public int Status; public byte* Message; }
    [StructLayout(LayoutKind.Sequential)] public struct Pair { public byte* Key; public byte* Value; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CBib
    {
        public byte* Id, Title, Subtitle;
        public byte** Authors;
        public nuint AuthorsCount;
        public byte* Format, PublicationDate, Edition, CallNumber, Summary, JacketSmall, JacketLarge, MaterialType;
        public byte Holdable;
        public byte* Status;
        public long HeldCopies, AvailableCopies, TotalCopies, OnOrderCopies;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CHold
    {
        public byte* Id, MetadataId, Status;
        public byte HasPosition;
        public long Position;
        public byte* PickupLocation, ExpiryDate, PickupByDate, SuspendEndDate;
        public byte CanCancel;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CCheckout
    {
        public byte* Id, MetadataId, Status, DueDate, CheckoutDate;
        public byte HasTimesRenewed;
        public long TimesRenewed;
    }

    [StructLayout(LayoutKind.Sequential)] public struct CHistoryEntry { public byte* Id, MetadataId, CheckoutDate, ReturnedDate; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CAccountStatus
    {
        public byte* Kind;
        public byte Ready, HasPosition;
        public long Position;
        public byte* Due;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CListEntry
    {
        public byte* Id;
        public CBib Bib;
        public byte* Kind;
        public long ServerIndex;
        public CHold* Hold;
        public CCheckout* Checkout;
        public CHistoryEntry* History;
        public CAccountStatus* AccountStatus;
    }

    [StructLayout(LayoutKind.Sequential)] public struct CFacetValue { public byte* Value; public long Count; }
    [StructLayout(LayoutKind.Sequential)] public struct CFacet { public byte* Id; public CFacetValue* Values; public nuint ValuesCount; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CListPage
    {
        public void* Owner;
        public CListEntry* Entries;
        public nuint EntriesCount;
        public long Page, Pages, Count, PageSize;
        public CFacet* Facets;
        public nuint FacetsCount;
        public byte** SortOptions;
        public nuint SortOptionsCount;
        public byte* AppliedSort;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CCopy
    {
        public byte* Id, Branch, Status;
        public byte IsAvailable;
        public byte* Collection, CallNumber, DueDate;
        public byte IsOnOrder;
        public byte* Kind;
    }

    [StructLayout(LayoutKind.Sequential)] public struct CDetailField { public byte* Label; public byte** Values; public nuint ValuesCount; }
    [StructLayout(LayoutKind.Sequential)] public struct CLocation { public byte* Id, Name; }
    [StructLayout(LayoutKind.Sequential)] public struct CRefusal { public byte* HoldId, Reason; }

    [StructLayout(LayoutKind.Sequential)] public struct CCopyList { public void* Owner; public CCopy* Items; public nuint ItemsCount; }
    [StructLayout(LayoutKind.Sequential)] public struct CDetailList { public void* Owner; public CDetailField* Items; public nuint ItemsCount; }
    [StructLayout(LayoutKind.Sequential)] public struct CLocationList { public void* Owner; public CLocation* Items; public nuint ItemsCount; }
    [StructLayout(LayoutKind.Sequential)] public struct CRefusalList { public void* Owner; public CRefusal* Items; public nuint ItemsCount; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CPatron
    {
        public void* Owner;
        public long UserId, AccountId;
        public byte* Name, Email, Language, Barcode, PreferredPickup;
        public byte HasBorrowingHistoryEnabled, BorrowingHistoryEnabled;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CLibraryInfo
    {
        public void* Owner;
        public byte* Subdomain, Name, ShortName, PrimaryColor, Website;
        public Pair* Labels;
        public nuint LabelsCount;
        public byte** Languages;
        public nuint LanguagesCount;
        public byte** Users;
        public nuint UsersCount;
    }

    [StructLayout(LayoutKind.Sequential)] public struct CDirectoryEntry { public byte* Name, Website, Region, Logo; }
    [StructLayout(LayoutKind.Sequential)] public struct CDirectoryPage { public void* Owner; public CDirectoryEntry* Entries; public nuint EntriesCount; public byte* Next; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CSearchQuery
    {
        public byte* Query, SearchType;
        public Pair* Filters;
        public nuint FilterCount;
        public long Page;
        public byte* Sort, Format;
    }

    [StructLayout(LayoutKind.Sequential)] public struct CHoldRef { public byte* Id, MetadataId; }

    // MARK: Functions

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_free(void* ptr);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_error_clear(Error* err);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern byte* biblio_subdomain_from(byte* input);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_library_info(byte* subdomain, CLibraryInfo** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_directory_page(byte* url, CDirectoryPage** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern byte* biblio_resolve_subdomain(byte* name, byte* website);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern byte* biblio_format_name(byte* code, Pair* labels, nuint count);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern byte* biblio_sort_name(byte* id, Pair* labels, nuint count);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern double* biblio_codabar(byte* value, nuint* count);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_library_icon(byte* website, byte* subdomain, byte* logo, byte** bytes, nuint* len);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern byte biblio_logo_bounds(byte* pixels, nuint width, nuint height, nuint stride, nuint channels, nuint* bounds);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_login(IntPtr client, byte force, CPatron** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_patron(IntPtr client, CPatron** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_search(IntPtr client, CSearchQuery* query, CListPage** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_holds(IntPtr client, long page, byte* sort, CListPage** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_checkouts(IntPtr client, long page, byte* sort, CListPage** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_history(IntPtr client, long page, byte* sort, CListPage** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_availability(IntPtr client, byte* metadataId, CCopyList** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_details(IntPtr client, byte* metadataId, CDetailList** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_locations(IntPtr client, CLocationList** @out, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_place_hold(IntPtr client, byte* metadataId, byte* materialType, byte* pickupBranch, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_cancel_holds(IntPtr client, CHoldRef* holds, nuint count, CRefusalList** refused, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_set_pickup(IntPtr client, byte* branchId, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_set_language(IntPtr client, byte* code, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_set_borrowing_history(IntPtr client, byte enabled, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_change_email(IntPtr client, byte* email, Error* err);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern int biblio_change_password(IntPtr client, byte* current, byte* @new, Error* err);

    // Every result struct starts with the arena that owns it, so its free functions are interchangeable.
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_page_free(void* result);

    // MARK: Library operations

    public static string? SubdomainFrom(string input)
    {
        using var s = new Strings();
        return Take(biblio_subdomain_from(s[input]));
    }

    public static LibraryInfo GetLibraryInfo(string subdomain)
    {
        using var s = new Strings();
        Error err = default;
        CLibraryInfo* p = null;
        return Finish(biblio_library_info(s[subdomain], &p, &err), &err, p, ToLibraryInfo);
    }

    public static DirectoryPage GetDirectoryPage(string? url)
    {
        using var s = new Strings();
        Error err = default;
        CDirectoryPage* p = null;
        return Finish(biblio_directory_page(s[url], &p, &err), &err, p, (CDirectoryPage* c) => new DirectoryPage(
            Items(c->Entries, c->EntriesCount, d => new DirectoryEntry(Str(d.Name), Opt(d.Website), Opt(d.Region), Opt(d.Logo))), Opt(c->Next)));
    }

    public static string? ResolveSubdomain(string name, string? website)
    {
        using var s = new Strings();
        return Take(biblio_resolve_subdomain(s[name], s[website]));
    }

    public static string? FormatName(string code, IReadOnlyDictionary<string, string>? labels)
    {
        using var s = new Strings();
        var pairs = s.Pairs(labels);
        fixed (Pair* l = pairs) return Take(biblio_format_name(s[code], l, (nuint)pairs.Length));
    }

    public static string? SortName(string id, IReadOnlyDictionary<string, string>? labels)
    {
        using var s = new Strings();
        var pairs = s.Pairs(labels);
        fixed (Pair* l = pairs) return Take(biblio_sort_name(s[id], l, (nuint)pairs.Length));
    }

    public static double[] Codabar(string value)
    {
        using var s = new Strings();
        nuint count;
        var widths = biblio_codabar(s[value], &count);
        if (widths == null) return [];
        try { return new ReadOnlySpan<double>(widths, (int)count).ToArray(); }
        finally { biblio_free(widths); }
    }

    /// <summary>A library's icon (PNG, ICO, GIF, BMP or JPEG), or null; a logo is wide, to trim with LogoBounds.</summary>
    public static (bool IsLogo, byte[] Bytes)? LibraryIcon(string? website, string? subdomain, string? logo)
    {
        using var s = new Strings();
        byte* bytes = null;
        nuint len;
        var kind = biblio_library_icon(s[website], s[subdomain], s[logo], &bytes, &len);
        if (bytes == null) return null;
        try { return (kind == 2, new ReadOnlySpan<byte>(bytes, (int)len).ToArray()); }
        finally { biblio_free(bytes); }
    }

    /// <summary>The part of a decoded logo that isn't white margin: x, y, width, height; null if blank.</summary>
    public static int[]? LogoBounds(byte[] pixels, int width, int height, int stride, int channels)
    {
        if (width <= 0 || height <= 0 || pixels.Length < (height - 1) * stride + width * channels) return null;
        var bounds = stackalloc nuint[4];
        fixed (byte* p = pixels)
            if (biblio_logo_bounds(p, (nuint)width, (nuint)height, (nuint)stride, (nuint)channels, bounds) == 0) return null;
        return [(int)bounds[0], (int)bounds[1], (int)bounds[2], (int)bounds[3]];
    }

    // MARK: Client operations

    public static Patron Login(IntPtr client, bool force)
    {
        Error err = default;
        CPatron* p = null;
        return Finish(biblio_login(client, force ? (byte)1 : (byte)0, &p, &err), &err, p, ToPatron);
    }

    /// <summary>The patron from the last sign-in, or null (no network).</summary>
    public static Patron? GetPatron(IntPtr client)
    {
        Error err = default;
        CPatron* p = null;
        var result = biblio_patron(client, &p, &err);
        return result == 0 && p == null ? null : Finish(result, &err, p, ToPatron);
    }

    public static ListPage Search(IntPtr client, string query, string? searchType, IReadOnlyDictionary<string, string>? filters,
        int page, string? sort, string? format)
    {
        using var s = new Strings();
        var pairs = s.Pairs(filters);
        Error err = default;
        CListPage* p = null;
        fixed (Pair* f = pairs)
        {
            var q = new CSearchQuery
            {
                Query = s[query], SearchType = s[searchType], Filters = f, FilterCount = (nuint)pairs.Length,
                Page = page, Sort = s[sort], Format = s[format],
            };
            return Finish(biblio_search(client, &q, &p, &err), &err, p, ToListPage);
        }
    }

    public enum Borrowing { Holds, Checkouts, History }

    public static ListPage BorrowingList(IntPtr client, Borrowing list, int page, string? sort)
    {
        using var s = new Strings();
        Error err = default;
        CListPage* p = null;
        var result = list switch
        {
            Borrowing.Holds => biblio_holds(client, page, s[sort], &p, &err),
            Borrowing.Checkouts => biblio_checkouts(client, page, s[sort], &p, &err),
            _ => biblio_history(client, page, s[sort], &p, &err),
        };
        return Finish(result, &err, p, ToListPage);
    }

    public static List<CopyAvailability> Availability(IntPtr client, string metadataId)
    {
        using var s = new Strings();
        Error err = default;
        CCopyList* p = null;
        return Finish(biblio_availability(client, s[metadataId], &p, &err), &err, p,
            (CCopyList* c) => Items(c->Items, c->ItemsCount, ToCopy));
    }

    public static List<DetailField> Details(IntPtr client, string metadataId)
    {
        using var s = new Strings();
        Error err = default;
        CDetailList* p = null;
        return Finish(biblio_details(client, s[metadataId], &p, &err), &err, p,
            (CDetailList* c) => Items(c->Items, c->ItemsCount, f => new DetailField(Str(f.Label), Strs(f.Values, f.ValuesCount))));
    }

    public static List<Location> Locations(IntPtr client)
    {
        Error err = default;
        CLocationList* p = null;
        return Finish(biblio_locations(client, &p, &err), &err, p,
            (CLocationList* c) => Items(c->Items, c->ItemsCount, l => new Location(Str(l.Id), Str(l.Name))));
    }

    public static void PlaceHold(IntPtr client, string metadataId, string? materialType, string? pickupBranch)
    {
        using var s = new Strings();
        Error err = default;
        Check(biblio_place_hold(client, s[metadataId], s[materialType], s[pickupBranch], &err), &err);
    }

    /// <summary>The holds the library declined to cancel (often none).</summary>
    public static List<Refusal> CancelHolds(IntPtr client, IEnumerable<Hold> holds)
    {
        using var s = new Strings();
        var refs = holds.Select(h => new CHoldRef { Id = s[h.Id], MetadataId = s[h.MetadataId] }).ToArray();
        Error err = default;
        CRefusalList* p = null;
        fixed (CHoldRef* r = refs)
        {
            return Finish(biblio_cancel_holds(client, r, (nuint)refs.Length, &p, &err), &err, p,
                (CRefusalList* c) => Items(c->Items, c->ItemsCount, x => new Refusal(Str(x.HoldId), Str(x.Reason))));
        }
    }

    public static void SetPickup(IntPtr client, string branchId)
    {
        using var s = new Strings();
        Error err = default;
        Check(biblio_set_pickup(client, s[branchId], &err), &err);
    }

    public static void SetLanguage(IntPtr client, string code)
    {
        using var s = new Strings();
        Error err = default;
        Check(biblio_set_language(client, s[code], &err), &err);
    }

    public static void SetBorrowingHistory(IntPtr client, bool enabled)
    {
        Error err = default;
        Check(biblio_set_borrowing_history(client, enabled ? (byte)1 : (byte)0, &err), &err);
    }

    public static void ChangeEmail(IntPtr client, string email)
    {
        using var s = new Strings();
        Error err = default;
        Check(biblio_change_email(client, s[email], &err), &err);
    }

    public static void ChangePassword(IntPtr client, string current, string @new)
    {
        using var s = new Strings(secret: true);
        Error err = default;
        Check(biblio_change_password(client, s[current], s[@new], &err), &err);
    }

    // MARK: Converting results

    private static Bib ToBib(in CBib b) => new(
        Str(b.Id), Str(b.Title), Opt(b.Subtitle), Strs(b.Authors, b.AuthorsCount), Opt(b.Format) ?? "UNKNOWN", Opt(b.PublicationDate),
        Opt(b.Edition), Opt(b.CallNumber), Opt(b.Summary), Opt(b.JacketSmall), Opt(b.JacketLarge), Opt(b.MaterialType) ?? "PHYSICAL",
        b.Holdable != 0, Opt(b.Status), (int)b.HeldCopies, (int)b.AvailableCopies, (int)b.TotalCopies, (int)b.OnOrderCopies);

    private static Hold ToHold(CHold* h) => new(
        Str(h->Id), Str(h->MetadataId), Str(h->Status), h->HasPosition != 0 ? (int)h->Position : null, Opt(h->PickupLocation),
        Opt(h->ExpiryDate), Opt(h->PickupByDate), Opt(h->SuspendEndDate), h->CanCancel != 0);

    private static ListEntry ToEntry(CListEntry e) => new(
        Str(e.Id), ToBib(e.Bib), Str(e.Kind), (int)e.ServerIndex,
        e.Hold == null ? null : ToHold(e.Hold),
        e.Checkout == null ? null : new Checkout(Str(e.Checkout->Id), Str(e.Checkout->MetadataId), Opt(e.Checkout->Status),
            Opt(e.Checkout->DueDate), Opt(e.Checkout->CheckoutDate), e.Checkout->HasTimesRenewed != 0 ? (int)e.Checkout->TimesRenewed : null),
        e.History == null ? null : new HistoryEntry(Str(e.History->Id), Str(e.History->MetadataId), Opt(e.History->CheckoutDate), Opt(e.History->ReturnedDate)),
        e.AccountStatus == null ? null : new AccountStatus(Str(e.AccountStatus->Kind), e.AccountStatus->Ready != 0,
            e.AccountStatus->HasPosition != 0 ? (int)e.AccountStatus->Position : null, Opt(e.AccountStatus->Due)));

    private static ListPage ToListPage(CListPage* p) => new(
        Items(p->Entries, p->EntriesCount, ToEntry), (int)p->Page, (int)p->Pages, (int)p->Count, (int)p->PageSize,
        Items(p->Facets, p->FacetsCount, f => new Facet(Str(f.Id), Items(f.Values, f.ValuesCount, v => new FacetValue(Str(v.Value), (int)v.Count)))),
        Strs(p->SortOptions, p->SortOptionsCount), Opt(p->AppliedSort));

    private static CopyAvailability ToCopy(CCopy c) => new(
        Str(c.Id), Str(c.Branch), Str(c.Status), c.IsAvailable != 0, Opt(c.Collection), Opt(c.CallNumber), Opt(c.DueDate),
        c.IsOnOrder != 0, Opt(c.Kind) ?? "other");

    private static Patron ToPatron(CPatron* p) => new(
        p->UserId, p->AccountId, Str(p->Name), Opt(p->Email), Str(p->Language), Opt(p->Barcode), Opt(p->PreferredPickup),
        p->HasBorrowingHistoryEnabled != 0 ? p->BorrowingHistoryEnabled != 0 : null);

    private static LibraryInfo ToLibraryInfo(CLibraryInfo* l)
    {
        var labels = new Dictionary<string, string>();
        foreach (var pair in Items(l->Labels, l->LabelsCount, x => x)) labels[Str(pair.Key)] = Str(pair.Value);
        return new LibraryInfo(Str(l->Subdomain), Str(l->Name), Opt(l->ShortName), Opt(l->PrimaryColor), Opt(l->Website),
            labels, Strs(l->Languages, l->LanguagesCount), []);
    }

    // MARK: Helpers

    private static string? Opt(byte* s) => s == null ? null : Marshal.PtrToStringUTF8((IntPtr)s);
    private static string Str(byte* s) => Opt(s) ?? "";

    private static List<string> Strs(byte** items, nuint count)
    {
        var list = new List<string>((int)count);
        for (nuint i = 0; i < count; i++) list.Add(Str(items[i]));
        return list;
    }

    private static List<R> Items<T, R>(T* items, nuint count, Func<T, R> convert) where T : unmanaged
    {
        var list = new List<R>((int)count);
        for (nuint i = 0; i < count; i++) list.Add(convert(items[i]));
        return list;
    }

    /// <summary>Takes a string the core allocated.</summary>
    private static string? Take(byte* s)
    {
        try { return Opt(s); }
        finally { if (s != null) biblio_free(s); }
    }

    private delegate R Convert<T, R>(T* result) where T : unmanaged;

    /// <summary>Throws the call's error, or converts and frees its result.</summary>
    private static R Finish<T, R>(int result, Error* err, T* value, Convert<T, R> convert) where T : unmanaged
    {
        try
        {
            Check(result, err);
            if (value == null) throw new CoreException("unexpected", "The library returned an unexpected response.");
            return convert(value);
        }
        finally { if (value != null) biblio_list_page_free(value); }
    }

    private static void Check(int result, Error* err)
    {
        try
        {
            if (result == 0) return;
            throw new CoreException(KindName(result), Opt(err->Message) ?? "Something went wrong.", err->Status != 0 ? err->Status : null);
        }
        finally { biblio_error_clear(err); }
    }

    private static string KindName(int result) => result switch
    {
        1 => "signInRequired",
        2 => "missingCredentials",
        3 => "loginFailed",
        4 => "http",
        5 => "network",
        7 => "notALibrary",
        8 => "badRequest",
        9 => "outOfMemory",
        _ => "unexpected",
    };

    /// <summary>UTF-8 copies of a call's string arguments, freed when the call is done.</summary>
    private sealed class Strings(bool secret = false) : IDisposable
    {
        private readonly List<(IntPtr Ptr, int Length)> _copies = [];

        public byte* this[string? s]
        {
            get
            {
                if (s is null) return null;
                var p = Marshal.StringToCoTaskMemUTF8(s);
                _copies.Add((p, secret ? System.Text.Encoding.UTF8.GetByteCount(s) : 0));
                return (byte*)p;
            }
        }

        public Pair[] Pairs(IReadOnlyDictionary<string, string>? map) =>
            map?.Select(kv => new Pair { Key = this[kv.Key], Value = this[kv.Value] }).ToArray() ?? [];

        public void Dispose()
        {
            foreach (var (p, length) in _copies)
            {
                // Passwords are wiped before the memory is released.
                if (length > 0) new Span<byte>((void*)p, length).Clear();
                Marshal.FreeCoTaskMem(p);
            }
        }
    }
}
