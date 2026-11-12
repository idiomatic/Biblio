using System.Runtime.InteropServices;

namespace Biblio.Core;

/// <summary>
/// libbiblio's item list (core/src/list.zig, <c>biblio_list_*</c> in biblio.h): which pages to fetch and
/// which rows to show, with sorting and filtering, shared with the other apps. It makes no requests;
/// the app fetches the pages it asks for and hands them to <see cref="Apply"/>. Use one from a single
/// thread (the UI thread), as the core requires.
/// </summary>
public sealed unsafe class CoreList : IDisposable
{
    private const string Lib = "libbiblio.dll";

    public enum Kind { Search, Holds, Checkouts, History }

    /// <summary>Server keeps the server's order; the others sort fetched items and need every page.</summary>
    public enum Sort { Server, PeopleWaiting, Title }

    /// <summary>Holds shown by status; None shows all.</summary>
    public enum HoldFilter { None, Ready, NotReady, OnOrder }

    public readonly record struct State(long Total, long Pages, bool Loaded, bool HasMore, bool Loading, bool Refreshing, bool Background, ulong Generation);

    /// <summary>A fetched item's id at a server position, or a placeholder (null id) for one not yet fetched.</summary>
    public readonly record struct Row(long Position, string? Id);

    // MARK: C structs (keep in step with biblio.h)

    [StructLayout(LayoutKind.Sequential)]
    private struct CState
    {
        public long Total, Pages;
        public byte Loaded, HasMore, Loading, Refreshing, Background;
        public ulong Generation;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CItem
    {
        public byte* Id, Title, Format;
        public long HeldCopies, ServerIndex;
        public byte IsHold, Ready, OnOrder;
        public long DueDay;
        public byte StatusRank;
        public byte* Author;
    }

    [StructLayout(LayoutKind.Sequential)] private struct CRow { public long Position; public byte* Id; }
    [StructLayout(LayoutKind.Sequential)] private struct CFormat { public byte* Format; public long Count; }

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr biblio_list_new(int kind);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_free(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern CState biblio_list_state(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern ulong biblio_list_reload(IntPtr list, [MarshalAs(UnmanagedType.U1)] bool keepContent);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_begin_refresh(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_clear(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool biblio_list_request(IntPtr list, long page);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool biblio_list_apply(IntPtr list, ulong generation, long page, CItem* items, nuint count, long total, long pageSize, long nowMs);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool biblio_list_fail(IntPtr list, ulong generation, long page);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool biblio_list_is_stale(IntPtr list, long nowMs);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern long biblio_list_item_appeared(IntPtr list, long position);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_placeholder_appeared(IntPtr list, long position);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_placeholder_disappeared(IntPtr list, long position);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern nuint biblio_list_take_visible_requests(IntPtr list, long* pages, nuint capacity);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool biblio_list_needs_all_pages(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool biblio_list_wants_all_pages(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.U1)] private static extern bool biblio_list_begin_background(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern long biblio_list_next_background_page(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_end_background(IntPtr list);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_set_sort(IntPtr list, int sort);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_set_format(IntPtr list, byte* format);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_set_hold_filter(IntPtr list, int filter);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_list_set_not_borrowed(IntPtr list, IntPtr* indexes, nuint count);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern nuint biblio_list_remove(IntPtr list, byte** ids, nuint count);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern long biblio_list_hold_count(IntPtr list, int filter);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern CRow* biblio_list_rows(IntPtr list, nuint* count);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern CFormat* biblio_list_formats(IntPtr list, nuint* count);

    private IntPtr _handle;

    public CoreList(Kind kind) => _handle = biblio_list_new((int)kind);

    public State GetState()
    {
        var s = biblio_list_state(_handle);
        return new State(s.Total, s.Pages, s.Loaded != 0, s.HasMore != 0, s.Loading != 0, s.Refreshing != 0, s.Background != 0, s.Generation);
    }

    public ulong Generation => biblio_list_state(_handle).Generation;

    /// <summary>Starts again from page 1, which it requests; returns the generation to apply results with.</summary>
    public ulong Reload(bool keepContent) => biblio_list_reload(_handle, keepContent);

    /// <summary>Marks the rows stale before such a reload (while signing in afresh).</summary>
    public void BeginRefresh() => biblio_list_begin_refresh(_handle);

    /// <summary>Empties the list without requesting anything (an empty search).</summary>
    public void Clear() => biblio_list_clear(_handle);

    public bool Request(int page) => biblio_list_request(_handle, page);

    /// <summary>Hands the list a fetched page. False if the list was reloaded since the page was requested.</summary>
    public bool Apply(ulong generation, ListPage page, long nowMs)
    {
        var entries = page.Entries;
        var items = new CItem[entries.Count];
        var strings = new List<IntPtr>(entries.Count * 4);
        try
        {
            byte* Utf8(string s)
            {
                var p = Marshal.StringToCoTaskMemUTF8(s);
                strings.Add(p);
                return (byte*)p;
            }
            for (var i = 0; i < items.Length; i++)
            {
                var e = entries[i];
                items[i] = new CItem
                {
                    Id = Utf8(e.Id),
                    Title = Utf8(e.Bib.Title),
                    Format = Utf8(e.Bib.Format),
                    HeldCopies = e.Bib.HeldCopies,
                    ServerIndex = e.ServerIndex,
                    IsHold = (byte)(e.Hold is not null ? 1 : 0),
                    Ready = (byte)(e.Hold is { IsReady: true } ? 1 : 0),
                    OnOrder = (byte)(e.Bib.Status == "ON_ORDER" || e.Bib.OnOrderCopies > 0 ? 1 : 0),
                    DueDay = DayNumber(e.Checkout?.DueDate),
                    StatusRank = e.Hold is { } h ? StatusRank(h) : (byte)0,
                    Author = Utf8(e.Bib.PrimaryAuthor ?? ""),
                };
            }
            fixed (CItem* p = items)
                return biblio_list_apply(_handle, generation, page.Page, p, (nuint)items.Length, page.Count, page.PageSize, nowMs);
        }
        finally
        {
            foreach (var s in strings) Marshal.FreeCoTaskMem(s);
        }
    }

    /// <summary>Days since 1970-01-01 of a "YYYY-MM-DD…" date; 0 if it isn't one.</summary>
    private static long DayNumber(string? date) =>
        date is { Length: >= 10 } && DateOnly.TryParseExact(date[..10], "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.None, out var d)
            ? d.DayNumber - DateOnly.FromDateTime(DateTime.UnixEpoch).DayNumber
            : 0;

    /// <summary>A hold's place in the status sort: ready, in transit, not yet available (or anything else), paused.</summary>
    private static byte StatusRank(Hold hold) => (byte)(hold.IsReady ? 0 : hold.Status switch
    {
        "READY_FOR_PICKUP" or "READY" => 0,
        "IN_TRANSIT" or "SHIPPED" or "READY_SOON" => 1,
        "SUSPENDED" or "INACTIVE" => 3,
        _ => 2,
    });

    public bool Fail(ulong generation, int page) => biblio_list_fail(_handle, generation, page);
    public bool IsStale(long nowMs) => biblio_list_is_stale(_handle, nowMs);

    /// <summary>An item in view: a page to prefetch, or 0.</summary>
    public int ItemAppeared(long position) => (int)biblio_list_item_appeared(_handle, position);

    public void PlaceholderAppeared(long position) => biblio_list_placeholder_appeared(_handle, position);
    public void PlaceholderDisappeared(long position) => biblio_list_placeholder_disappeared(_handle, position);

    /// <summary>The pages of placeholders that have stayed on screen briefly; each is then in flight.</summary>
    public List<int> TakeVisibleRequests()
    {
        var pages = stackalloc long[64];
        var n = (int)biblio_list_take_visible_requests(_handle, pages, 64);
        var result = new List<int>(n);
        for (var i = 0; i < n; i++) result.Add((int)pages[i]);
        return result;
    }

    public bool NeedsAllPages => biblio_list_needs_all_pages(_handle);
    public bool WantsAllPages => biblio_list_wants_all_pages(_handle);
    public bool BeginBackground() => biblio_list_begin_background(_handle);

    /// <summary>The next page to fetch in the background, or 0 when done.</summary>
    public int NextBackgroundPage() => (int)biblio_list_next_background_page(_handle);

    public void EndBackground() => biblio_list_end_background(_handle);

    public void SetSort(Sort sort) => biblio_list_set_sort(_handle, (int)sort);

    /// <summary>The format filter for account lists, applied locally; null for all.</summary>
    public void SetFormat(string? format)
    {
        var p = format is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(format);
        try { biblio_list_set_format(_handle, (byte*)p); }
        finally { if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p); }
    }

    public void SetHoldFilter(HoldFilter filter) => biblio_list_set_hold_filter(_handle, (int)filter);

    /// <summary>
    /// "Not Borrowed": shows only works none of these indexes borrowed in the item's format; none turns it
    /// off. The indexes must outlive the setting; set it again after their generation changes.
    /// </summary>
    public void SetNotBorrowed(IReadOnlyList<BorrowedIndex> indexes)
    {
        var handles = indexes.Select(i => i.Handle).Where(h => h != IntPtr.Zero).ToArray();
        fixed (IntPtr* p = handles) biblio_list_set_not_borrowed(_handle, p, (nuint)handles.Length);
    }
    public int HoldCount(HoldFilter filter) => (int)biblio_list_hold_count(_handle, (int)filter);

    /// <summary>The rows to show, after sorting and filtering.</summary>
    public List<Row> Rows()
    {
        nuint n;
        var rows = biblio_list_rows(_handle, &n);
        var result = new List<Row>((int)n);
        for (nuint i = 0; i < n; i++)
            result.Add(new Row(rows[i].Position, rows[i].Id == null ? null : Marshal.PtrToStringUTF8((IntPtr)rows[i].Id)));
        return result;
    }

    /// <summary>The loaded items' formats with counts, most common first.</summary>
    public List<FacetValue> Formats()
    {
        nuint n;
        var formats = biblio_list_formats(_handle, &n);
        var result = new List<FacetValue>((int)n);
        for (nuint i = 0; i < n; i++)
            result.Add(new FacetValue(Marshal.PtrToStringUTF8((IntPtr)formats[i].Format) ?? "", (int)formats[i].Count));
        return result;
    }

    public void Dispose()
    {
        if (_handle != IntPtr.Zero) biblio_list_free(_handle);
        _handle = IntPtr.Zero;
    }
}
