using System.Runtime.InteropServices;
using System.Text.Json;

namespace Biblio.Core;

/// <summary>
/// The bridge to libbiblio (libbiblio.dll), the Zig core shared with the Apple, Android, GNOME, and terminal apps.
/// Each operation is a typed C function (see core/include/biblio.h and Interop.cs) returning the
/// app's records or throwing <see cref="CoreException"/>. Calls block, so they run on the thread pool.
/// </summary>
/// <remarks>biblio_result, value for value.</remarks>
public enum Result
{
    Ok = 0,
    /// <summary>An account operation on a guest client.</summary>
    SignInRequired,
    /// <summary>The password callback returned nothing.</summary>
    MissingCredentials,
    /// <summary>The library rejected the username or password.</summary>
    LoginFailed,
    /// <summary>The gateway or website returned an error status.</summary>
    Http,
    /// <summary>The library could not be reached.</summary>
    Network,
    /// <summary>The library refused (a hold, say), or a page could not be read.</summary>
    Unexpected,
    /// <summary>No BiblioCommons catalog at that subdomain.</summary>
    NotALibrary,
    /// <summary>A missing argument or client: a bug in the app.</summary>
    BadRequest,
    OutOfMemory,
    /// <summary>The library refused a hold: the account has as many as it allows.</summary>
    HoldLimit,
}

/// <summary>biblio_hold_rank: where a hold's status falls in the status sort.</summary>
public enum HoldRank { Ready = 0, InTransit, Waiting, Paused }

public sealed class CoreException(Result kind, string message, int? status = null) : Exception(message)
{
    public Result Kind { get; } = kind;
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

/// <summary>
/// A native client, freed once the last call using it returns: every P/Invoke holds a reference to the
/// handle for its duration, so disposing it while calls run on the thread pool defers the free. It
/// owns the GCHandle that gives the password callback its password source.
/// </summary>
internal sealed class ClientHandle : SafeHandle
{
    private GCHandle _password;

    private ClientHandle() : base(IntPtr.Zero, ownsHandle: true) { }

    public override bool IsInvalid => handle == IntPtr.Zero;

    public static ClientHandle Create(string subdomain, string username, Func<string?> password)
    {
        var h = new ClientHandle { _password = GCHandle.Alloc(password) };
        var client = Interop.ClientNew(subdomain, username, GCHandle.ToIntPtr(h._password));
        if (client == IntPtr.Zero)
        {
            h._password.Free();
            h.SetHandleAsInvalid();
            throw new CoreException(Result.OutOfMemory, "Biblio ran out of memory.");
        }
        h.SetHandle(client);
        return h;
    }

    protected override bool ReleaseHandle()
    {
        Interop.ClientFree(handle);
        if (_password.IsAllocated) _password.Free();
        return true;
    }
}

/// <summary>A client's latest request to the library, for the status bar. Used from the UI thread.</summary>
public sealed class FetchStatus
{
    public sealed record Fetch(string Title, string Url, ulong Bytes);

    public Fetch? Last { get; private set; }
    /// <summary>Requests started but not finished.</summary>
    public int Active { get; private set; }
    /// <summary>A request started or finished.</summary>
    public event Action? Changed;

    internal void Began()
    {
        Active++;
        Changed?.Invoke();
    }

    internal void Finished(Fetch? fetch)
    {
        Active = Math.Max(0, Active - 1);
        if (fetch is not null) Last = fetch;
        Changed?.Invoke();
    }
}

/// <summary>One core client: a (library, username) session, or a guest when the username is empty.</summary>
public sealed class CoreClient : IDisposable
{
    public string Subdomain { get; }
    public string Username { get; }
    public bool IsGuest => Username.Length == 0;
    public FetchStatus Status { get; } = new();

    private readonly ClientHandle _handle;

    /// <summary><paramref name="password"/> runs on the thread pool whenever the core signs in.</summary>
    public CoreClient(string subdomain, string username, Func<string?> password)
    {
        Subdomain = subdomain;
        Username = username;
        _handle = ClientHandle.Create(subdomain, username, password);
    }

    /// <summary>Runs a blocking core call on the thread pool; throws ObjectDisposedException once disposed.</summary>
    private async Task<T> Run<T>(Func<ClientHandle, T> call)
    {
        ObjectDisposedException.ThrowIf(_handle.IsClosed, this);
        FetchStatus.Fetch? last = null;
        Status.Began();
        try
        {
            return await Task.Run(() =>
            {
                try { return call(_handle); }
                finally { last = LastFetch(); }
            });
        }
        finally { Status.Finished(last); }
    }

    private FetchStatus.Fetch? LastFetch()
    {
        try { return Interop.LastFetch(_handle) is { } f ? new FetchStatus.Fetch(f.Title, f.Url, f.Bytes) : null; }
        catch (ObjectDisposedException) { return null; }
    }

    private Task Run(Action<ClientHandle> call) => Run(h => { call(h); return true; });

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

    /// <summary>A history page as the core's own result, for <see cref="BorrowedIndex"/>, which frees it.</summary>
    public Task<IntPtr> CoreHistoryPageAsync(int page) => Run(h => Interop.CoreHistoryPage(h, page));

    public Task<List<CopyAvailability>> AvailabilityAsync(string metadataId) => Run(h => Interop.Availability(h, metadataId));

    /// <summary>Full record fields ("Details", "About", …).</summary>
    public Task<List<DetailField>> DetailsAsync(string metadataId) => Run(h => Interop.Details(h, metadataId));

    public Task<List<Location>> LocationsAsync() => Run(Interop.Locations);

    /// <summary>A null <paramref name="pickupBranch"/> uses the account's preferred branch.</summary>
    public Task PlaceHoldAsync(string metadataId, string? materialType, string? pickupBranch) =>
        Run(h => Interop.PlaceHold(h, metadataId, materialType, pickupBranch));

    /// <summary>Returns the holds the library declined to cancel, with its reasons (often none).</summary>
    public Task<List<Refusal>> CancelHoldsAsync(IEnumerable<Hold> holds) => Run(h => Interop.CancelHolds(h, holds));

    /// <summary>The email, pickup location, and language the library has now.</summary>
    public Task<AccountSettings> AccountSettingsAsync() => Run(Interop.GetAccountSettings);

    /// <summary>Sets the language the client asks the library for (null leaves it); no network request.</summary>
    public void Configure(string? language) => Interop.Configure(_handle, language);

    public Task SetPickupAsync(string branchId) => Run(h => Interop.SetPickup(h, branchId));
    public Task SetLanguageAsync(string code) => Run(h => Interop.SetLanguage(h, code));
    public Task SetBorrowingHistoryAsync(bool enabled) => Run(h => Interop.SetBorrowingHistory(h, enabled));
    public Task ChangeEmailAsync(string email) => Run(h => Interop.ChangeEmail(h, email));

    /// <summary>The app must then save the new password.</summary>
    public Task ChangePasswordAsync(string current, string @new) => Run(h => Interop.ChangePassword(h, current, @new));

    /// <summary>Frees the native client once calls still running on the thread pool finish.</summary>
    public void Dispose() => _handle.Dispose();
}

/// <summary>Operations that need no account.</summary>
public static class Core
{
    /// <summary>Name, brand color, languages, and catalog labels from the library's public search page.</summary>
    public static Task<LibraryInfo> LibraryInfoAsync(string subdomain) => Task.Run(() => Interop.GetLibraryInfo(subdomain));

    /// <summary>A page of BiblioCommons' partner directory: null for the first, then each page's Next.</summary>
    public static Task<DirectoryPage> DirectoryPageAsync(string? url) => Task.Run(() => Interop.GetDirectoryPage(url));

    /// <summary>Guesses and confirms a directory entry's catalog subdomain.</summary>
    public static Task<string?> ResolveSubdomainAsync(string name, string? website) => Task.Run(() => Interop.ResolveSubdomain(name, website));

    /// <summary>Whether a BiblioCommons catalog exists at the subdomain.</summary>
    public static Task<bool> LibraryExistsAsync(string subdomain) => Task.Run(() => Interop.LibraryExists(subdomain));

    /// <summary>An image through the core's shared throttle.</summary>
    public static Task<byte[]> FetchImageAsync(string url) => Task.Run(() => Interop.FetchImage(url));

    // Display helpers (no network)

    /// <summary>A scanned card number without Codabar A–D start and stop characters; null if empty or not printable ASCII.</summary>
    public static string? CardNormalize(string scanned) => Interop.CardNormalize(scanned);

    /// <summary>"wccls" from "WCCLS", "https://smpl.bibliocommons.com/", …; null if it isn't one.</summary>
    public static string? SubdomainFrom(string input) => Interop.SubdomainFrom(input);

    public static string FormatName(string code, IReadOnlyDictionary<string, string>? labels) => Interop.FormatName(code, labels) ?? code;
    public static string SortName(string id, IReadOnlyDictionary<string, string>? labels) => Interop.SortName(id, labels) ?? id;

    /// <summary>A format the core refines from a broader one (4K Ultra HD Blu-ray filed as Blu-ray); searches filter it locally.</summary>
    public static bool IsRefinedFormat(string code) => Interop.IsRefinedFormat(code);

    /// <summary>Codabar, or Code 128, bar and space widths in narrow units, bar first; empty if the value can't be encoded.</summary>
    public static double[] Barcode(string value, bool code128 = false) => Interop.Barcode(value, code128);

    /// <summary>A "#RRGGBB" color adjusted to 4.5:1 contrast on a light or dark background; null if it isn't one.</summary>
    public static string? ReadableTint(string hex, bool dark) => Interop.ReadableTint(hex, dark);

    /// <summary>The format codes with built-in names, for format pickers.</summary>
    public static List<string> FormatCodes() => Interop.FormatCodes();

    /// <summary>Where a hold's status falls in the status sort.</summary>
    public static HoldRank HoldStatusRank(string? status) => Interop.HoldStatusRank(status);

    /// <summary>"Ready for pickup", "In transit", "On hold", or "Paused".</summary>
    public static string HoldStatusName(string? status) => Interop.HoldStatusName(status);

    /// <summary>The year a publication date names ("c2019." gives "2019"), else the date as given.</summary>
    public static string? Year(string? date) => Interop.Year(date);

    /// <summary>Throttling and failures the servers have shown since launch, as JSON.</summary>
    public static string Incidents() => Interop.Incidents();
}
