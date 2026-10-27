using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Biblio.Views;

public enum Section { Search, NewTitles, Holds, Checkouts, History, Account }

/// <summary>
/// One account's window (or a guest's): a NavigationView of sections, the section's list, and
/// the selected item's details beside it (or over it when the window is narrow).
/// </summary>
public sealed class AccountWindow : Window
{
    /// <summary>
    /// Open windows by login: BiblioCommons ends a session when the same login signs in
    /// elsewhere, so each login gets one window.
    /// </summary>
    private static readonly Dictionary<string, AccountWindow> OpenWindows = [];

    public LibraryInfo Library { get; }
    public string Username { get; }
    public bool IsGuest => Username.Length == 0;
    public CoreClient Client { get; }
    public Patron? Patron { get; private set; }
    public List<Location> Locations { get; private set; } = [];

    private readonly NavigationView _nav = new();
    private readonly InfoBar _message = new() { IsClosable = true };
    private readonly Dictionary<Section, ItemListView> _lists = [];
    private readonly Dictionary<Section, NavigationViewItem> _items = [];
    private AccountPage? _account;

    public static bool IsOpen(string subdomain, string username) => OpenWindows.ContainsKey($"{subdomain}|{username}");

    public static void Open(LibraryInfo library, string username)
    {
        var key = $"{library.Subdomain}|{username}";
        if (username.Length > 0 && OpenWindows.TryGetValue(key, out var existing))
        {
            existing.Activate();
            return;
        }
        var window = new AccountWindow(library, username);
        if (username.Length > 0) OpenWindows[key] = window;
        window.Closed += (_, _) =>
        {
            OpenWindows.Remove(key);
            window.Client.Dispose();
        };
        window.Activate();
    }

    private AccountWindow(LibraryInfo library, string username)
    {
        Library = library;
        Username = username;
        var store = LibraryStore.Shared;
        Client = new CoreClient(library.Subdomain, username, () => store.Password(library.Subdomain, username));
        Title = $"{library.DisplayName} — {(IsGuest ? "Guest" : username)}";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 800));

        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Auto;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _nav.IsSettingsVisible = false;
        _nav.PaneTitle = library.DisplayName;
        AddItem(Section.Search, "Search", Symbol.Find);
        AddItem(Section.NewTitles, "New Titles", Symbol.Favorite);
        if (!IsGuest)
        {
            AddItem(Section.Holds, "Holds", Symbol.Bookmarks);
            AddItem(Section.Checkouts, "Checked Out", Symbol.Library);
            AddItem(Section.History, "Borrowing History", Symbol.Clock);
            var account = new NavigationViewItem { Content = "Account", Icon = new SymbolIcon(Symbol.Contact), Tag = Section.Account };
            _items[Section.Account] = account;
            _nav.FooterMenuItems.Add(account);
        }
        var switchItem = new NavigationViewItem { Content = "Switch User or Library", Icon = new SymbolIcon(Symbol.Switch), SelectsOnInvoked = false };
        switchItem.Tapped += (_, _) => LauncherWindow.Open();
        _nav.FooterMenuItems.Add(switchItem);
        _nav.SelectionChanged += (_, args) =>
        {
            if (args.SelectedItemContainer?.Tag is Section s) Show(s);
        };

        _message.Margin = new Thickness(12);
        _message.VerticalAlignment = VerticalAlignment.Bottom;
        _message.HorizontalAlignment = HorizontalAlignment.Center;
        _message.MaxWidth = 640;
        var root = new Grid
        {
            RowDefinitions = { new RowDefinition { Height = new GridLength(32) }, new RowDefinition() },
            Children = { LauncherWindow.TitleBarText(Title), LauncherWindow.WithRow(_nav, 1), LauncherWindow.WithRow(_message, 1) },
        };
        Content = root;
        _nav.SelectedItem = _items[Section.Search];
        _ = Start();
    }

    private void AddItem(Section section, string title, Symbol icon)
    {
        var item = new NavigationViewItem { Content = title, Icon = new SymbolIcon(icon), Tag = section };
        _items[section] = item;
        _nav.MenuItems.Add(item);
    }

    private async Task Start()
    {
        try { Locations = await Client.CallAsync<List<Location>>("locations"); } catch (CoreException) { }
        if (IsGuest) return;
        try
        {
            Patron = await Client.CallAsync<Patron>("login");
            // Fill the hold and checkout counts without waiting for those lists to be opened.
            ListFor(Section.Holds).LoadIfNeeded();
            ListFor(Section.Checkouts).LoadIfNeeded();
            _account?.Refresh();
        }
        catch (CoreException e) { ShowMessage(e.Message, error: true); }
    }

    public ItemListView ListFor(Section section)
    {
        if (!_lists.TryGetValue(section, out var list)) _lists[section] = list = new ItemListView(this, section);
        return list;
    }

    private void Show(Section section)
    {
        if (section == Section.Account)
        {
            _account ??= new AccountPage(this);
            _account.Refresh();
            _nav.Content = _account;
        }
        else
        {
            var list = ListFor(section);
            _nav.Content = list;
            list.LoadIfNeeded();
        }
    }

    public void ShowSection(Section section) => _nav.SelectedItem = _items[section];

    public void SetCount(Section section, int count)
    {
        if (_items.TryGetValue(section, out var item))
            item.InfoBadge = count > 0 ? new InfoBadge { Value = count } : null;
    }

    public void ShowMessage(string message, bool error = false)
    {
        _message.Message = message;
        _message.Severity = error ? InfoBarSeverity.Error : InfoBarSeverity.Success;
        _message.IsOpen = true;
    }

    public async Task RefreshPatron()
    {
        try { Patron = await Client.CallAsync<Patron?>("patron") ?? Patron; } catch (CoreException) { }
    }

    /// <summary>After placing or cancelling a hold.</summary>
    public void HoldsChanged()
    {
        if (_lists.TryGetValue(Section.Holds, out var holds)) holds.Reload();
        foreach (var s in new[] { Section.Search, Section.NewTitles })
            if (_lists.TryGetValue(s, out var l)) l.ReloadIfLoaded();
    }
}

/// <summary>Copy-status colors; the status is always written out too.</summary>
public static class StatusBrushes
{
    public static Brush Copy(string kind) => new SolidColorBrush(kind switch
    {
        "available" => Microsoft.UI.ColorHelper.FromArgb(255, 16, 124, 16),
        "onOrder" => Microsoft.UI.ColorHelper.FromArgb(255, 0, 120, 110),
        "out" or "other" => Microsoft.UI.ColorHelper.FromArgb(255, 157, 93, 0),
        "held" => Microsoft.UI.ColorHelper.FromArgb(255, 118, 54, 160),
        "transit" => Microsoft.UI.ColorHelper.FromArgb(255, 0, 90, 158),
        "repair" => Microsoft.UI.ColorHelper.FromArgb(255, 121, 85, 72),
        "missing" or "claimsReturned" => Microsoft.UI.ColorHelper.FromArgb(255, 196, 43, 28),
        _ => Microsoft.UI.ColorHelper.FromArgb(255, 112, 112, 112),
    });

    public static Brush Availability(string? status) => Copy(status switch
    {
        "AVAILABLE" => "available",
        "ON_ORDER" => "onOrder",
        "UNAVAILABLE" or "NOT_AVAILABLE" => "out",
        _ => "withdrawn",
    });
}
