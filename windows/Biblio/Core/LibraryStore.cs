using System.Collections.ObjectModel;
using System.Text.Json;
using Windows.Security.Credentials;

namespace Biblio.Core;

/// <summary>
/// Added libraries and their usernames (JSON in local app data); passwords in the Windows
/// Credential Locker (PasswordVault), one credential per library and username.
/// </summary>
public sealed class LibraryStore
{
    public static LibraryStore Shared { get; } = new();

    public ObservableCollection<LibraryInfo> Libraries { get; } = [];

    private readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Biblio", "libraries.json");
    private readonly PasswordVault _vault = new();

    private LibraryStore()
    {
        try
        {
            if (File.Exists(_path) && JsonSerializer.Deserialize<List<LibraryInfo>>(File.ReadAllText(_path), CoreJson.Options) is { } list)
                foreach (var lib in list) Libraries.Add(lib);
        }
        catch (JsonException) { }
    }

    public LibraryInfo? Library(string subdomain) => Libraries.FirstOrDefault(l => l.Subdomain == subdomain);

    public void Upsert(LibraryInfo info)
    {
        var i = IndexOf(info.Subdomain);
        if (i >= 0) Libraries[i] = info with { Users = Libraries[i].Users };
        else Libraries.Add(info with { Users = [] });
        Save();
    }

    public void Remove(string subdomain)
    {
        foreach (var user in Library(subdomain)?.Users ?? []) DeletePassword(subdomain, user);
        var i = IndexOf(subdomain);
        if (i >= 0) Libraries.RemoveAt(i);
        Save();
    }

    public void AddUser(string subdomain, string username, string password)
    {
        var i = IndexOf(subdomain);
        if (i < 0) return;
        SetPassword(subdomain, username, password);
        var users = Libraries[i].Users ?? [];
        if (!users.Contains(username)) Libraries[i] = Libraries[i] with { Users = [.. users, username] };
        Save();
    }

    public void RemoveUser(string subdomain, string username)
    {
        var i = IndexOf(subdomain);
        if (i < 0) return;
        DeletePassword(subdomain, username);
        Libraries[i] = Libraries[i] with { Users = (Libraries[i].Users ?? []).Where(u => u != username).ToList() };
        Save();
    }

    private int IndexOf(string subdomain)
    {
        for (var i = 0; i < Libraries.Count; i++) if (Libraries[i].Subdomain == subdomain) return i;
        return -1;
    }

    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, JsonSerializer.Serialize(Libraries.ToList(), CoreJson.Options));
    }

    private static string Resource(string subdomain) => $"Biblio – {subdomain}.bibliocommons.com";

    public string? Password(string subdomain, string username)
    {
        try
        {
            var credential = _vault.Retrieve(Resource(subdomain), username);
            credential.RetrievePassword();
            return credential.Password;
        }
        catch (Exception) { return null; } // not found
    }

    public void SetPassword(string subdomain, string username, string password)
    {
        DeletePassword(subdomain, username);
        _vault.Add(new PasswordCredential(Resource(subdomain), username, password));
    }

    public void DeletePassword(string subdomain, string username)
    {
        try { _vault.Remove(_vault.Retrieve(Resource(subdomain), username)); }
        catch (Exception) { }
    }
}
