using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Biblio.Views;

/// <summary>Finds a library by catalog subdomain or address, or by name from BiblioCommons' partner list.</summary>
public static class AddLibraryDialog
{
    private static readonly List<DirectoryEntry> Directory = [];
    private static Task? _loading;

    /// <summary>Loads the partner directory once, page by page, in the background.</summary>
    private static Task LoadDirectory() => _loading ??= Task.Run(async () =>
    {
        string? next = null;
        var seen = new HashSet<string>();
        do
        {
            DirectoryPage page;
            try { page = await Core.Core.CallAsync<DirectoryPage>("directoryPage", new { url = next }); }
            catch (CoreException) { break; }
            var fresh = page.Entries.Where(e => seen.Add(e.Name)).ToList();
            lock (Directory) Directory.AddRange(fresh);
            if (fresh.Count == 0) break;
            next = page.Next;
        } while (next is not null);
    });

    /// <summary>True if a library was added.</summary>
    public static async Task<bool> Show(XamlRoot root)
    {
        _ = LoadDirectory();
        var box = new AutoSuggestBox
        {
            Header = "Library", PlaceholderText = "wccls or https://wccls.bibliocommons.com",
            Description = "Enter the name before “.bibliocommons.com” in your library’s catalog address, or search by library name.",
            QueryIcon = new SymbolIcon(Symbol.Find),
        };
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
        var progress = new ProgressRing { IsActive = false, Width = 20, Height = 20 };
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = "Add Library",
            Content = new StackPanel { Spacing = 12, MinWidth = 400, Children = { box, progress, error } },
            PrimaryButtonText = "Add", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        var added = false;

        box.TextChanged += (sender, args) =>
        {
            if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
            var t = sender.Text.Trim();
            List<DirectoryEntry> matches;
            lock (Directory)
                matches = t.Length < 2 ? [] : Directory
                    .Where(e => e.Name.Contains(t, StringComparison.OrdinalIgnoreCase) || (e.Website?.Contains(t, StringComparison.OrdinalIgnoreCase) ?? false))
                    .Take(12).ToList();
            sender.ItemsSource = matches.Select(e => e.Name).ToList();
        };

        async Task<bool> Add(string? subdomain)
        {
            error.IsOpen = false;
            if (subdomain is null)
            {
                error.Message = "Enter a library name or catalog address.";
                error.IsOpen = true;
                return false;
            }
            progress.IsActive = true;
            try
            {
                LibraryStore.Shared.Upsert(await Core.Core.CallAsync<LibraryInfo>("libraryInfo", new { subdomain }));
                added = true;
                return true;
            }
            catch (CoreException e)
            {
                error.Message = e.Message;
                error.IsOpen = true;
                return false;
            }
            finally { progress.IsActive = false; }
        }

        box.SuggestionChosen += async (_, args) =>
        {
            DirectoryEntry? entry;
            lock (Directory) entry = Directory.FirstOrDefault(e => e.Name == (string)args.SelectedItem);
            if (entry is null) return;
            progress.IsActive = true;
            var sub = await Core.Core.CallAsync<string?>("resolveSubdomain", new { name = entry.Name, website = entry.Website });
            progress.IsActive = false;
            if (sub is null)
            {
                error.Message = $"Couldn’t find the catalog for {entry.Name}. Enter its subdomain instead.";
                error.IsOpen = true;
            }
            else if (await Add(sub)) dialog.Hide();
        };

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            var sub = Core.Core.CallNow<string?>("subdomainFrom", new { input = box.Text });
            args.Cancel = !await Add(sub);
            deferral.Complete();
        };
        await dialog.ShowAsync();
        return added;
    }
}

/// <summary>Signs in once to check the username and password before saving them.</summary>
public static class AddUserDialog
{
    /// <summary>The username added, or null.</summary>
    public static async Task<string?> Show(XamlRoot root, LibraryInfo library)
    {
        var username = new TextBox { Header = "Username or card number" };
        var password = new PasswordBox { Header = "PIN or password" };
        var note = new TextBlock
        {
            Text = "Your password is stored in Windows Credential Locker and used to sign in again when the library ends your session.",
            TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        };
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = $"Sign In to {library.DisplayName}",
            Content = new StackPanel { Spacing = 12, MinWidth = 360, Children = { username, password, note, error } },
            PrimaryButtonText = "Sign In", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        string? added = null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            var user = username.Text.Trim();
            var pw = password.Password;
            if (user.Length == 0 || pw.Length == 0 || AccountWindow.IsOpen(library.Subdomain, user))
            {
                error.Message = user.Length == 0 || pw.Length == 0 ? "Enter a username and password." :
                    $"{user} is already signed in in another window. Close that window first.";
                error.IsOpen = true;
                args.Cancel = true;
                deferral.Complete();
                return;
            }
            using var client = new CoreClient(library.Subdomain, user, () => pw);
            try
            {
                await client.CallAsync<Patron>("login", new { force = true });
                LibraryStore.Shared.AddUser(library.Subdomain, user, pw);
                added = user;
            }
            catch (CoreException e)
            {
                error.Message = e.Message;
                error.IsOpen = true;
                args.Cancel = true;
            }
            deferral.Complete();
        };
        await dialog.ShowAsync();
        return added;
    }
}
