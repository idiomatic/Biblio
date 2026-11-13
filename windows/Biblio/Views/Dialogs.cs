using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Biblio.Views;

/// <summary>Finds a library by catalog subdomain or address, or by name from BiblioCommons' partner list.</summary>
public static class AddLibraryDialog
{
    private static readonly List<DirectoryEntry> Directory = [];
    private static Task? _loading;

    /// <summary>Loads the partner directory page by page in the background; a failed load is tried again next time.</summary>
    private static Task LoadDirectory() => _loading ??= LoadPages();

    private static async Task LoadPages()
    {
        string? next = null;
        var failed = false;
        await Task.Run(async () =>
        {
            do
            {
                DirectoryPage page;
                try { page = await Core.Core.DirectoryPageAsync(next); }
                catch (CoreException) { failed = true; break; }
                lock (Directory)
                {
                    // A retry starts over from the first page, so pages already read aren't added twice.
                    var fresh = page.Entries.Where(e => !Directory.Any(d => d.Name == e.Name)).ToList();
                    Directory.AddRange(fresh);
                    if (fresh.Count == 0) break;
                }
                next = page.Next;
            } while (next is not null);
        });
        if (failed) _loading = null;
    }

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
                LibraryStore.Shared.Upsert(await Core.Core.LibraryInfoAsync(subdomain));
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
            var sub = await Core.Core.ResolveSubdomainAsync(entry.Name, entry.Website);
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
            var sub = Core.Core.SubdomainFrom(box.Text);
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
                await client.LoginAsync(force: true);
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

/// <summary>
/// A guest's sign-in sheet: the library's saved users (one open in another window is disabled, with
/// the reason) plus "Add User…"; the sign-in form straight away if it has none.
/// </summary>
public static class SignInDialog
{
    /// <summary>The username chosen or added, or null.</summary>
    public static async Task<string?> Show(XamlRoot root, LibraryInfo library)
    {
        var users = library.Users ?? [];
        if (users.Count == 0) return await AddUserDialog.Show(root, library);
        string? chosen = null;
        var addUser = false;
        var list = new StackPanel { Spacing = 4, MinWidth = 360 };
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = $"Sign In to {library.DisplayName}", Content = list,
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };
        foreach (var user in users)
        {
            var open = AccountWindow.IsOpen(library.Subdomain, user);
            var card = new CommunityToolkit.WinUI.Controls.SettingsCard
            {
                Header = user, HeaderIcon = new SymbolIcon(Symbol.Contact), IsClickEnabled = !open, IsEnabled = !open,
            };
            if (open) card.Description = "Open in another window";
            card.Click += (_, _) => { chosen = user; dialog.Hide(); };
            list.Children.Add(card);
        }
        var add = new CommunityToolkit.WinUI.Controls.SettingsCard { Header = "Add User…", HeaderIcon = new SymbolIcon(Symbol.AddFriend), IsClickEnabled = true };
        add.Click += (_, _) => { addUser = true; dialog.Hide(); };
        list.Children.Add(add);
        await dialog.ShowAsync();
        // One dialog at a time: the form opens once the sheet has closed.
        return addUser ? await AddUserDialog.Show(root, library) : chosen;
    }
}
