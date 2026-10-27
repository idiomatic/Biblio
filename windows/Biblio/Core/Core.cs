using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Biblio.Core;

/// <summary>
/// The bridge to libbiblio (biblio.dll), the Zig core shared with the Apple, Android and GNOME apps.
/// Every operation is a JSON request answered with {"ok": true, "result": …} or {"ok": false,
/// "error": {…}} (see core/include/biblio.h). Calls block, so they run on the thread pool.
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

    [DllImport("biblio.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr biblio_call(IntPtr client, byte[] request);

    /// <summary>NUL-terminated UTF-8.</summary>
    public static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s + "\0");
}

public sealed class CoreException(string kind, string message, int? status = null) : Exception(message)
{
    public string Kind { get; } = kind;
    public int? Status { get; } = status;
}

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

    public async Task<T> CallAsync<T>(string op, object? args = null)
    {
        lock (_lock)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(CoreClient));
            _inFlight++;
        }
        try { return await Core.CallAsync<T>(_handle, op, args); }
        finally { lock (_lock) { if (--_inFlight == 0 && _disposed) Free(); } }
    }

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

public static class Core
{
    /// <summary>Runs an operation that needs no account (library lookup, display helpers).</summary>
    public static Task<T> CallAsync<T>(string op, object? args = null) => CallAsync<T>(IntPtr.Zero, op, args);

    /// <summary>Runs an operation that never touches the network (formatName, codabar) right away.</summary>
    public static T CallNow<T>(string op, object? args = null) => Decode<T>(Invoke(IntPtr.Zero, Request(op, args)));

    internal static Task<T> CallAsync<T>(IntPtr client, string op, object? args)
    {
        var request = Request(op, args);
        return Task.Run(() => Decode<T>(Invoke(client, request)));
    }

    private static byte[] Request(string op, object? args)
    {
        var node = args is null ? new JsonObject() : JsonSerializer.SerializeToNode(args, CoreJson.Options)!.AsObject();
        node["op"] = op;
        return Native.Utf8(node.ToJsonString());
    }

    private static string Invoke(IntPtr client, byte[] request)
    {
        var result = Native.biblio_call(client, request);
        if (result == IntPtr.Zero) throw new CoreException("unexpected", "Biblio couldn’t reach its library engine.");
        try { return Marshal.PtrToStringUTF8(result) ?? ""; }
        finally { Native.biblio_free(result); }
    }

    private static T Decode<T>(string json)
    {
        var response = JsonNode.Parse(json)!.AsObject();
        if (response["ok"]?.GetValue<bool>() == true)
            return response["result"] is { } r ? r.Deserialize<T>(CoreJson.Options)! : default!;
        var error = response["error"];
        throw new CoreException(
            error?["kind"]?.GetValue<string>() ?? "unexpected",
            error?["message"]?.GetValue<string>() ?? "Something went wrong.",
            error?["status"]?.GetValue<int>());
    }
}
