using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Biblio.Core;

/// <summary>
/// What one card borrowed before, from its borrowing history: libbiblio's index (core/src/borrowed.zig,
/// <c>biblio_borrowed_*</c> in biblio.h), synced in the background through the shared throttle and kept
/// in a file in local app data, which stays on this device. Nothing is kept while the library's
/// borrowing history is off. Use one from a single thread (the UI thread), as the core requires.
/// </summary>
public sealed class BorrowedIndex : IDisposable
{
    private const string Lib = "libbiblio.dll";

    /// <summary>The patron borrowed this item, or this work in another format.</summary>
    public sealed record Match(bool SameFormat, string Format, int Count, string? LastCheckout, string? LastReturned);

    // MARK: C structs (keep in step with biblio.h)

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct CBorrowed
    {
        public int Match; // biblio_borrowed_match: 0 none, 1 same, 2 other format
        public byte* Format;
        public long Count;
        public byte* LastCheckout, LastReturned;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CProgress
    {
        public long Fetched, Total;
        public byte Complete, Syncing;
    }

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr biblio_borrowed_index_new();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_borrowed_index_free(IntPtr index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.U1)] private static extern unsafe bool biblio_borrowed_index_import(IntPtr index, byte* bytes, nuint len);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern unsafe byte* biblio_borrowed_index_export(IntPtr index, nuint* len);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_borrowed_index_clear(IntPtr index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern long biblio_borrowed_index_begin_sync(IntPtr index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern long biblio_borrowed_index_rebuild(IntPtr index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern long biblio_borrowed_index_apply_page(IntPtr index, long page, IntPtr result);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern void biblio_borrowed_index_fail(IntPtr index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern CProgress biblio_borrowed_index_progress(IntPtr index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern ulong biblio_borrowed_index_generation(IntPtr index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] private static extern unsafe CBorrowed biblio_borrowed(IntPtr index, byte* metadataId, byte* format, byte* title, byte* author);

    public string Subdomain { get; }
    public string Username { get; }

    private IntPtr _handle;
    private bool _loaded;
    /// <summary>Bumped to stop a running sync loop (cleared or disposed).</summary>
    private int _run;

    /// <summary>Entries indexed, and the history's size as the library last reported it.</summary>
    public long Fetched { get; private set; }
    public long Total { get; private set; }
    /// <summary>Every page fetched once: matches are complete, and "Not Borrowed" is offered.</summary>
    public bool IsComplete { get; private set; }
    public bool IsSyncing { get; private set; }
    /// <summary>Changes with the matches, so rows showing them update.</summary>
    public ulong Generation { get; private set; }

    /// <summary>Progress or matches changed.</summary>
    public event Action? Changed;

    public BorrowedIndex(string subdomain, string username)
    {
        Subdomain = subdomain;
        Username = username;
        _handle = biblio_borrowed_index_new();
    }

    /// <summary>For <see cref="CoreList.SetNotBorrowed"/>; valid until disposed.</summary>
    internal IntPtr Handle => _handle;

    // MARK: Syncing

    /// <summary>
    /// After signing in: forgets everything when the library keeps no history, else loads the saved
    /// index and brings it up to date.
    /// </summary>
    public void Start(CoreClient client, bool? historyEnabled)
    {
        if (historyEnabled == false) { Clear(); return; }
        Sync(client);
    }

    /// <summary>Fetches what's new (or, the first time, every page, resuming where it stopped).</summary>
    public void Sync(CoreClient client)
    {
        if (_handle == IntPtr.Zero) return;
        LoadIfNeeded();
        _ = Run(biblio_borrowed_index_begin_sync(_handle), client);
    }

    /// <summary>Refresh Borrowing History: forgets the index and fetches it all again.</summary>
    public void Rebuild(CoreClient client)
    {
        if (_handle == IntPtr.Zero) return;
        LoadIfNeeded();
        var page = biblio_borrowed_index_rebuild(_handle);
        Save();
        // 0: a sync already running carries on from page 1.
        _ = Run(page, client);
    }

    /// <summary>Borrowing history turned off, or the card signed out: nothing stays on the device.</summary>
    public void Clear()
    {
        if (_handle == IntPtr.Zero) return;
        _run++;
        biblio_borrowed_index_clear(_handle);
        _loaded = true;
        DeleteFile(Subdomain, Username);
        Refresh();
    }

    private async Task Run(long first, CoreClient client)
    {
        Refresh();
        if (first <= 0) return;
        var run = _run;
        for (var page = first; page > 0;)
        {
            IntPtr result;
            try { result = await client.CoreHistoryPageAsync((int)page); }
            catch (Exception e) when (e is CoreException or ObjectDisposedException)
            {
                if (run == _run && _handle != IntPtr.Zero) biblio_borrowed_index_fail(_handle);
                break;
            }
            try
            {
                // Cleared or closed while the page was in flight: this loop is over.
                if (run != _run || _handle == IntPtr.Zero) return;
                page = biblio_borrowed_index_apply_page(_handle, page, result);
            }
            finally { Interop.FreeListPage(result); }
            Save();
            Refresh();
        }
        if (run == _run) Refresh();
    }

    private void Refresh()
    {
        if (_handle == IntPtr.Zero) return;
        var p = biblio_borrowed_index_progress(_handle);
        Fetched = p.Fetched;
        Total = p.Total;
        IsComplete = p.Complete != 0;
        IsSyncing = p.Syncing != 0;
        Generation = biblio_borrowed_index_generation(_handle);
        Changed?.Invoke();
    }

    // MARK: Matching

    /// <summary>Whether the patron borrowed this item, or the same work in another format.</summary>
    public unsafe Match? Lookup(Bib bib)
    {
        if (_handle == IntPtr.Zero || Fetched == 0) return null;
        var strings = new List<IntPtr>(4);
        try
        {
            byte* Utf8(string? s)
            {
                if (s is null) return null;
                var p = Marshal.StringToCoTaskMemUTF8(s);
                strings.Add(p);
                return (byte*)p;
            }
            var r = biblio_borrowed(_handle, Utf8(bib.Id), Utf8(bib.Format), Utf8(bib.Title), Utf8(bib.PrimaryAuthor));
            if (r.Match == 0) return null;
            return new Match(r.Match == 1, Str(r.Format) ?? "", (int)r.Count, Str(r.LastCheckout), Str(r.LastReturned));
        }
        finally
        {
            foreach (var s in strings) Marshal.FreeCoTaskMem(s);
        }
    }

    private static unsafe string? Str(byte* s) => s == null ? null : Marshal.PtrToStringUTF8((IntPtr)s);

    // MARK: Storage

    private unsafe void LoadIfNeeded()
    {
        if (_loaded) return;
        _loaded = true;
        try
        {
            var path = FilePath(Subdomain, Username);
            if (File.Exists(path))
            {
                var bytes = File.ReadAllBytes(path);
                fixed (byte* p = bytes) biblio_borrowed_index_import(_handle, p, (nuint)bytes.Length);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        Refresh();
    }

    private unsafe void Save()
    {
        // A card removed while its window is open keeps nothing.
        if (LibraryStore.Shared.Library(Subdomain)?.Users?.Contains(Username) != true) return;
        nuint len;
        var bytes = biblio_borrowed_index_export(_handle, &len);
        if (bytes == null) return;
        try
        {
            var path = FilePath(Subdomain, Username);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using var file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
            file.Write(new ReadOnlySpan<byte>(bytes, checked((int)len)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        finally { Interop.Free(bytes); }
    }

    /// <summary>
    /// One file per card in local app data (per user, and not roamed), named by a hash so the name
    /// doesn't say whose it is.
    /// </summary>
    private static string FilePath(string subdomain, string username)
    {
        var digest = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes($"{subdomain}|{username}")));
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Biblio", "Borrowed", $"{digest[..32]}.json");
    }

    /// <summary>Deletes a card's saved index (removing the card or its library).</summary>
    public static void DeleteFile(string subdomain, string username)
    {
        try { File.Delete(FilePath(subdomain, username)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Stops syncing and frees the core index; lists filtering on it must be freed first.</summary>
    public void Dispose()
    {
        _run++;
        if (_handle != IntPtr.Zero) biblio_borrowed_index_free(_handle);
        _handle = IntPtr.Zero;
    }
}
