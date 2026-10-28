using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Biblio.Core;

/// <summary>
/// The bridge to libbiblio (biblio.dll), the Zig core shared with the Apple, Android and GNOME apps.
/// Each operation is a typed C function (see core/include/biblio.h and Interop.cs) returning the
/// app's records or throwing <see cref="CoreException"/>. Calls block, so they run on the thread pool.
/// </summary>
public static partial class Native
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate IntPtr PasswordCallback(IntPtr ctx, IntPtr subdomain, IntPtr username);

    [DllImport("biblio.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr biblio_alloc(UIntPtr len);

    [DllImport("biblio.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void biblio_free(IntPtr ptr);

    [DllImport("biblio.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr biblio_client_new(byte[] subdomain, byte[] username, PasswordCallback password, IntPtr ctx);

    [DllImport("biblio.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void biblio_client_free(IntPtr client);

    /// <summary>NUL-terminated UTF-8.</summary>
    public static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s + "\0");
}

public sealed class CoreException(string kind, string message, int? status = null) : Exception(message)
{
    public string Kind { get; } = kind;
    public int? Status { get; } = status;
}

/// <summary>For saving <see cref="LibraryInfo"/> (see LibraryStore).</summary>
public static class CoreJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };
}

/// <summary>One core client: a (library, username) session, or a guest when the username is empty.</summary>
public sealed class CoreClient : IDisposable
{
    public string Subdomain { get; }
    public string Username { get; }
    public bool IsGuest => Username.Length == 0;

    private IntPtr _handle;
    // Kept alive for as long as the native client can call it.
    private readonly Native.PasswordCallback _password;

    public CoreClient(string subdomain, string username, Func<string?> password)
    {
        Subdomain = subdomain;
        Username = username;
        _password = (_, _, _) =>
        {
            var p = password();
            if (p is null) return IntPtr.Zero;
            var bytes = Native.Utf8(p);
            var mem = Native.biblio_alloc((UIntPtr)bytes.Length);
            Marshal.Copy(bytes, 0, mem, bytes.Length);
            Array.Clear(bytes);
            return mem;
        };
        _handle = Native.biblio_client_new(Native.Utf8(subdomain), Native.Utf8(username), _password, IntPtr.Zero);
    }

    private int _inFlight;
    private bool _disposed;
    private readonly object _lock = new();

    /// <summary>Runs a blocking core call on the thread pool.</summary>
    private async Task<T> Run<T>(Func<IntPtr, T> call)
    {
        IntPtr handle;
        lock (_lock)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(CoreClient));
            _inFlight++;
            handle = _handle;
        }
        try { return await Task.Run(() => call(handle)); }
        finally { lock (_lock) { if (--_inFlight == 0 && _disposed) Free(); } }
    }

    private Task Run(Action<IntPtr> call) => Run(h => { call(h); return true; });

    /// <summary>Signs in if needed (always, with <paramref name="force"/>) and returns the patron.</summary>
    public Task<Patron> LoginAsync(bool force = false) => Run(h => Interop.Login(h, force));

    /// <summary>The patron from the last sign-in (no network request).</summary>
    public Task<Patron?> PatronAsync() => Run(Interop.GetPatron);

    public Task<ListPage> SearchAsync(string query, string? searchType = null, IReadOnlyDictionary<string, string>? filters = null,
        int page = 1, string? sort = null, string? format = null) =>
        Run(h => Interop.Search(h, query, searchType, filters, page, sort, format));

    public Task<ListPage> HoldsAsync(int page, string? sort) => Run(h => Interop.BorrowingList(h, Interop.Borrowing.Holds, page, sort));
    public Task<ListPage> CheckoutsAsync(int page, string? sort) => Run(h => Interop.BorrowingList(h, Interop.Borrowing.Checkouts, page, sort));
    public Task<ListPage> HistoryAsync(int page, string? sort) => Run(h => Interop.BorrowingList(h, Interop.Borrowing.History, page, sort));

    public Task<List<CopyAvailability>> AvailabilityAsync(string metadataId) => Run(h => Interop.Availability(h, metadataId));

    /// <summary>Full record fields ("Details", "About", …).</summary>
    public Task<List<DetailField>> DetailsAsync(string metadataId) => Run(h => Interop.Details(h, metadataId));

    public Task<List<Location>> LocationsAsync() => Run(Interop.Locations);

    /// <summary>A null <paramref name="pickupBranch"/> uses the account's preferred branch.</summary>
    public Task PlaceHoldAsync(string metadataId, string? materialType, string? pickupBranch) =>
        Run(h => Interop.PlaceHold(h, metadataId, materialType, pickupBranch));

    /// <summary>Returns the holds the library declined to cancel, with its reasons (often none).</summary>
    public Task<List<Refusal>> CancelHoldsAsync(IEnumerable<Hold> holds) => Run(h => Interop.CancelHolds(h, holds));

    public Task SetPickupAsync(string branchId) => Run(h => Interop.SetPickup(h, branchId));
    public Task SetLanguageAsync(string code) => Run(h => Interop.SetLanguage(h, code));
    public Task SetBorrowingHistoryAsync(bool enabled) => Run(h => Interop.SetBorrowingHistory(h, enabled));
    public Task ChangeEmailAsync(string email) => Run(h => Interop.ChangeEmail(h, email));

    /// <summary>The app must then save the new password.</summary>
    public Task ChangePasswordAsync(string current, string @new) => Run(h => Interop.ChangePassword(h, current, @new));

    /// <summary>Frees the native client once calls still running on the thread pool finish.</summary>
    public void Dispose()
    {
        lock (_lock)
        {
            _disposed = true;
            if (_inFlight == 0) Free();
        }
    }

    private void Free()
    {
        if (_handle != IntPtr.Zero) Native.biblio_client_free(_handle);
        _handle = IntPtr.Zero;
    }
}

/// <summary>Operations that need no account.</summary>
public static class Core
{
    /// <summary>Name, brand color, languages and catalog labels from the library's public search page.</summary>
    public static Task<LibraryInfo> LibraryInfoAsync(string subdomain) => Task.Run(() => Interop.GetLibraryInfo(subdomain));

    /// <summary>A page of BiblioCommons' partner directory: null for the first, then each page's Next.</summary>
    public static Task<DirectoryPage> DirectoryPageAsync(string? url) => Task.Run(() => Interop.GetDirectoryPage(url));

    /// <summary>Guesses and confirms a directory entry's catalog subdomain.</summary>
    public static Task<string?> ResolveSubdomainAsync(string name, string? website) => Task.Run(() => Interop.ResolveSubdomain(name, website));

    // Display helpers (no network)

    /// <summary>"wccls" from "WCCLS", "https://smpl.bibliocommons.com/", …; null if it isn't one.</summary>
    public static string? SubdomainFrom(string input) => Interop.SubdomainFrom(input);

    public static string FormatName(string code, IReadOnlyDictionary<string, string>? labels) => Interop.FormatName(code, labels) ?? code;
    public static string SortName(string id, IReadOnlyDictionary<string, string>? labels) => Interop.SortName(id, labels) ?? id;

    /// <summary>Codabar bar and space widths in narrow units, bar first; empty if the value can't be encoded.</summary>
    public static double[] Codabar(string value) => Interop.Codabar(value);
}
