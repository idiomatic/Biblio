using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Biblio.Views;

public enum Section { Search, NewTitles, Holds, Checkouts, History, Account }

/// <summary>
/// One account's window (or a guest's): a NavigationView of sections, the section's list, and
/// the selected item's details beside it (or over it when the window is narrow), over a status bar.
/// A guest window becomes an account's when the guest signs in, keeping its search, section, and
/// selection.
/// </summary>
public sealed class AccountWindow : Window
{
    /// <summary>
    /// Open windows by login: BiblioCommons ends a session when the same login signs in
    /// elsewhere, so each login gets one window.
    /// </summary>
    private static readonly Dictionary<string, AccountWindow> OpenWindows = [];

    public LibraryInfo Library { get; }
    public string Username { get; private set; }
    public bool IsGuest => Username.Length == 0;
    public CoreClient Client { get; private set; }
    public Patron? Patron { get; private set; }
    public List<Location> Locations { get; private set; } = [];
    /// <summary>What this card borrowed before; null for guests.</summary>
    public BorrowedIndex? Borrowed { get; private set; }
    /// <summary>Status colors follow the window's theme.</summary>
    public bool IsDark => _root.ActualTheme == ElementTheme.Dark;

    private readonly Grid _root = new();
    private readonly TextBlock _titleText;
    private readonly NavigationView _nav = new();
    private readonly InfoBar _message = new() { IsClosable = true };
    private readonly Dictionary<Section, ItemListView> _lists = [];
    private readonly Dictionary<Section, NavigationViewItem> _items = [];
    private NavigationViewItem? _signIn;
    private AccountPage? _account;
    /// <summary>The sidebar badges loaded so far; borrowing history syncs once both have.</summary>
    private readonly HashSet<Section> _counted = [];
    private TaskCompletionSource _badges = new();

    // The status bar: the latest request, fading after a quiet spell.
    private readonly Border _statusBar;
    private readonly TextBlock _statusText;
    private readonly ProgressRing _statusRing = new() { Width = 12, Height = 12, IsActive = false };
    private readonly DispatcherTimer _statusFade = new() { Interval = TimeSpan.FromSeconds(2) };
    /// <summary>A success notice closes itself; an error stays until it's closed.</summary>
    private readonly DispatcherTimer _messageFade = new() { Interval = TimeSpan.FromSeconds(6) };

    private static string Key(string subdomain, string username) => $"{subdomain}|{username}";

    public static bool IsOpen(string subdomain, string username) => OpenWindows.ContainsKey(Key(subdomain, username));

    public static void Open(LibraryInfo library, string username)
    {
        if (username.Length > 0 && OpenWindows.TryGetValue(Key(library.Subdomain, username), out var existing))
        {
            existing.Activate();
            return;
        }
        var window = new AccountWindow(library, username);
        window.Closed += (_, _) =>
        {
            if (!window.IsGuest) OpenWindows.Remove(Key(library.Subdomain, window.Username));
            window._statusFade.Stop();
            window._messageFade.Stop();
            foreach (var list in window._lists.Values) list.Dispose();
            // After the lists, whose "Not Borrowed" filters point at it.
            window.Borrowed?.Dispose();
            window.Client.Dispose();
            DiagnosticLog.Sync();
        };
        window.Activate();
    }

    private AccountWindow(LibraryInfo library, string username)
    {
        Library = library;
        Username = username;
        Client = NewClient(username);
        if (!IsGuest)
        {
            OpenWindows[Key(library.Subdomain, username)] = this;
            Borrowed = NewBorrowed(username);
        }
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        LauncherWindow.Resize(this, 1200, 800);

        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Auto;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _nav.IsSettingsVisible = false;
        _nav.PaneTitle = library.DisplayName;
        AddItem(Section.Search, "Search", Symbol.Find);
        AddItem(Section.NewTitles, "New Titles", Symbol.Favorite);
        if (IsGuest)
        {
            _signIn = new NavigationViewItem { Content = "Sign In", Icon = new SymbolIcon(Symbol.Contact), SelectsOnInvoked = false };
            _signIn.Tapped += async (_, _) => await SignInAsync();
            _nav.FooterMenuItems.Add(_signIn);
        }
        else AddAccountItems();
        var switchItem = new NavigationViewItem { Content = "Switch User or Library", Icon = new SymbolIcon(Symbol.Switch), SelectsOnInvoked = false };
        switchItem.Tapped += (_, _) => LauncherWindow.Open();
        _nav.FooterMenuItems.Add(switchItem);
        _nav.SelectionChanged += (_, args) =>
        {
            if (args.SelectedItemContainer?.Tag is Section s) Show(s);
        };

        // The version, subtly at the foot of the sidebar, opens the About box.
        var version = new HyperlinkButton
        {
            Content = new TextBlock { Text = $"Version {AboutDialog.Version}", Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] },
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], Margin = new Thickness(8, 0, 8, 8),
        };
        ToolTipService.SetToolTip(version, "About Biblio");
        version.Click += async (_, _) => await AboutDialog.Show(_root.XamlRoot);
        _nav.PaneFooter = version;
        _nav.PaneOpening += (_, _) => version.Visibility = Visibility.Visible;
        _nav.PaneClosing += (_, _) => version.Visibility = Visibility.Collapsed;

        _message.Margin = new Thickness(12);
        _message.VerticalAlignment = VerticalAlignment.Bottom;
        _message.HorizontalAlignment = HorizontalAlignment.Center;
        _message.MaxWidth = 640;

        _statusText = new TextBlock
        {
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], VerticalAlignment = VerticalAlignment.Center,
        };
        var statusContent = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        statusContent.Children.Add(_statusText);
        Grid.SetColumn(_statusRing, 1);
        statusContent.Children.Add(_statusRing);
        _statusBar = new Border
        {
            Child = statusContent, Padding = new Thickness(12, 3, 12, 4), MinHeight = 24, Opacity = 0,
            BorderThickness = new Thickness(0, 1, 0, 0), BorderBrush = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
            OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(400) },
        };
        _messageFade.Tick += (_, _) =>
        {
            _messageFade.Stop();
            _message.IsOpen = false;
        };
        _statusFade.Tick += (_, _) =>
        {
            _statusFade.Stop();
            _statusBar.Opacity = 0;
        };

        _titleText = LauncherWindow.TitleBarText("");
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        _root.RowDefinitions.Add(new RowDefinition());
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.Children.Add(_titleText);
        _root.Children.Add(LauncherWindow.WithRow(_nav, 1));
        _root.Children.Add(LauncherWindow.WithRow(_message, 1));
        _root.Children.Add(LauncherWindow.WithRow(_statusBar, 2));
        _root.ActualThemeChanged += (_, _) =>
        {
            foreach (var list in _lists.Values) list.ThemeChanged();
        };
        Content = _root;
        UpdateTitle();
        _nav.SelectedItem = _items[Section.Search];
        _ = Start();
    }

    private CoreClient NewClient(string username)
    {
        var store = LibraryStore.Shared;
        var subdomain = Library.Subdomain;
        var client = new CoreClient(subdomain, username, () => store.Password(subdomain, username));
        client.Status.Changed += StatusChanged;
        return client;
    }

    private BorrowedIndex NewBorrowed(string username)
    {
        var borrowed = new BorrowedIndex(Library.Subdomain, username);
        borrowed.Changed += BorrowedChanged;
        return borrowed;
    }

    private void UpdateTitle()
    {
        Title = $"{Library.DisplayName} — {(IsGuest ? "Guest" : Username)}";
        _titleText.Text = Title;
    }

    private void AddItem(Section section, string title, Symbol icon)
    {
        var item = new NavigationViewItem { Content = title, Icon = new SymbolIcon(icon), Tag = section };
        _items[section] = item;
        _nav.MenuItems.Add(item);
    }

    private void AddAccountItems()
    {
        AddItem(Section.Holds, "Holds", Symbol.Bookmarks);
        AddItem(Section.Checkouts, "Checked Out", Symbol.Library);
        AddItem(Section.History, "Borrowing History", Symbol.Clock);
        var account = new NavigationViewItem { Content = "Account", Icon = new SymbolIcon(Symbol.Contact), Tag = Section.Account };
        _items[Section.Account] = account;
        _nav.FooterMenuItems.Insert(0, account);

        // Dropping an item's cover (from any window's detail) onto Holds places a hold.
        var holds = _items[Section.Holds];
        holds.AllowDrop = true;
        holds.DragOver += (_, e) =>
        {
            if (ItemDrag.Current is not { Holdable: true }) return;
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.IsCaptionVisible = false;
            e.DragUIOverride.IsGlyphVisible = false;
        };
        holds.Drop += async (_, _) =>
        {
            if (ItemDrag.Current is { Holdable: true } bib) await PlaceHoldAsync(bib, null);
        };
    }

    private async Task Start()
    {
        // Guests can't read pickup locations; asking would only spend a throttled request.
        if (IsGuest) return;
        var client = Client;
        try { Locations = await client.LocationsAsync(); }
        catch (CoreException) { }
        catch (ObjectDisposedException) { return; }
        try
        {
            Patron = await client.LoginAsync();
            // A guest that just signed in has an item open: its hold controls need the locations and the preferred one.
            foreach (var list in _lists.Values) list.SignedIn();
            // Fill the hold and checkout counts without waiting for those lists to be opened.
            ListFor(Section.Holds).LoadIfNeeded();
            ListFor(Section.Checkouts).LoadIfNeeded();
            _account?.Refresh();
        }
        catch (CoreException e) { ShowMessage(e.Message, error: true); return; }
        catch (ObjectDisposedException) { return; }
        // Borrowing history syncs after the badges, so they come first through the shared throttle.
        await Task.WhenAny(_badges.Task, Task.Delay(TimeSpan.FromSeconds(15)));
        if (Patron is { } patron && client == Client) Borrowed?.Start(Client, patron.BorrowingHistoryEnabled);
    }

    // MARK: Signing in

    /// <summary>
    /// A guest's sign-in sheet: the library's saved users plus "Add User…", or the sign-in form if it
    /// has none. Signing in turns this window into that account's, keeping its search, section, and
    /// selection. True if signed in.
    /// </summary>
    public async Task<bool> SignInAsync()
    {
        if (!IsGuest) return true;
        var library = LibraryStore.Shared.Library(Library.Subdomain) ?? Library;
        if (await SignInDialog.Show(_root.XamlRoot, library) is not { } username || !IsGuest) return false;
        if (IsOpen(Library.Subdomain, username))
        {
            ShowMessage($"{username} is already signed in in another window.", error: true);
            return false;
        }
        var guest = Client;
        Username = username;
        Client = NewClient(username);
        guest.Status.Changed -= StatusChanged;
        guest.Dispose();
        OpenWindows[Key(Library.Subdomain, username)] = this;
        Borrowed = NewBorrowed(username);
        if (_signIn is not null) _nav.FooterMenuItems.Remove(_signIn);
        _signIn = null;
        AddAccountItems();
        UpdateTitle();
        _counted.Clear();
        _badges = new TaskCompletionSource();
        foreach (var list in _lists.Values) list.SignedIn();
        _ = Start();
        return true;
    }

    // MARK: Holds

    /// <summary>
    /// Places a hold at a pickup location (null: the preferred one), saying how it went; a guest is
    /// asked to sign in instead. True if placed.
    /// </summary>
    public async Task<bool> PlaceHoldAsync(Bib bib, string? pickup)
    {
        if (IsGuest)
        {
            await SignInAsync();
            return false;
        }
        try
        {
            await Client.PlaceHoldAsync(bib.Id, bib.MaterialType, pickup);
            ShowMessage($"Hold placed on “{bib.Title}”.");
            HoldsChanged();
            return true;
        }
        catch (CoreException e)
        {
            ShowMessage(e.Message, error: true);
            return false;
        }
        catch (ObjectDisposedException) { return false; }
    }

    /// <summary>Places holds one at a time and reports the outcome in one message; stops at the library's hold limit.</summary>
    public async Task PlaceHoldsAsync(IReadOnlyList<Bib> bibs)
    {
        if (IsGuest)
        {
            await SignInAsync();
            return;
        }
        var placed = 0;
        string? firstError = null;
        foreach (var bib in bibs)
        {
            try
            {
                await Client.PlaceHoldAsync(bib.Id, bib.MaterialType, null);
                placed++;
            }
            catch (CoreException e)
            {
                firstError ??= e.Message;
                // The library refuses everything after its hold limit; stop asking.
                if (e.Kind == Result.HoldLimit) break;
            }
            catch (ObjectDisposedException) { return; }
        }
        if (firstError is not null) ShowMessage($"Placed {placed} of {Plural(bibs.Count, "hold")}. {firstError}", error: true);
        else ShowMessage(placed == 1 ? "Hold placed." : $"{Plural(placed, "hold")} placed.");
        if (placed > 0) HoldsChanged();
    }

    /// <summary>Cancels holds, saying why the library refused any (some or all of them). True if any were canceled.</summary>
    public async Task<bool> CancelHoldsAsync(IReadOnlyList<(Hold Hold, string Title)> holds)
    {
        try
        {
            var refused = await Client.CancelHoldsAsync(holds.Select(h => h.Hold));
            var canceled = holds.Count - refused.Count;
            if (refused.Count == 0)
                ShowMessage(canceled == 1 ? "Hold canceled." : $"{Plural(canceled, "hold")} canceled.");
            else
            {
                var reasons = string.Join(" ", refused.Select(r =>
                    holds.FirstOrDefault(h => h.Hold.Id == r.HoldId).Title is { } title ? $"“{title}”: {r.Reason}" : r.Reason));
                ShowMessage(canceled == 0 ? (holds.Count == 1 ? refused[0].Reason : $"The library didn’t cancel these holds. {reasons}")
                    : $"Canceled {canceled} of {Plural(holds.Count, "hold")}. {reasons}", error: true);
            }
            if (canceled > 0) HoldsChanged();
            return canceled > 0;
        }
        catch (CoreException e)
        {
            ShowMessage(e.Message, error: true);
            return false;
        }
        catch (ObjectDisposedException) { return false; }
    }

    public static string Plural(int count, string noun) => count == 1 ? $"1 {noun}" : $"{count:N0} {noun}s";

    // MARK: Sections

    /// <summary>
    /// After the patron changes (signing in afresh): keeps nothing when the library's borrowing
    /// history is off, and syncs what's new otherwise.
    /// </summary>
    public void SignedIn(Patron patron)
    {
        Patron = patron;
        Borrowed?.Start(Client, patron.BorrowingHistoryEnabled);
    }

    /// <summary>The borrowed-before index's progress or matches changed.</summary>
    private void BorrowedChanged()
    {
        foreach (var list in _lists.Values) list.BorrowedChanged();
        _account?.UpdateBorrowed();
    }

    /// <summary>The account's hold on an item, if the Holds list has it.</summary>
    public Hold? HoldFor(string metadataId) => _lists.TryGetValue(Section.Holds, out var holds) ? holds.HoldFor(metadataId) : null;

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

    public void ShowSection(Section section)
    {
        if (_items.TryGetValue(section, out var item)) _nav.SelectedItem = item;
    }

    public void SetCount(Section section, int count)
    {
        if (_items.TryGetValue(section, out var item))
            item.InfoBadge = count > 0 ? new InfoBadge { Value = count } : null;
        if (_counted.Add(section) && _counted.Count == 2) _badges.TrySetResult();
    }

    public void ShowMessage(string message, bool error = false)
    {
        _message.Message = message;
        _message.Severity = error ? InfoBarSeverity.Error : InfoBarSeverity.Success;
        _message.IsOpen = true;
        _messageFade.Stop();
        if (!error) _messageFade.Start();
    }

    public async Task RefreshPatron()
    {
        try { Patron = await Client.PatronAsync() ?? Patron; }
        catch (CoreException) { }
        catch (ObjectDisposedException) { }
    }

    /// <summary>After placing or canceling a hold.</summary>
    public void HoldsChanged()
    {
        if (_lists.TryGetValue(Section.Holds, out var holds)) holds.Reload();
        foreach (var s in new[] { Section.Search, Section.NewTitles })
            if (_lists.TryGetValue(s, out var l)) l.ReloadIfLoaded();
    }

    // MARK: Status bar

    /// <summary>`TITLE [SIZE KiB]`, the URL on hover, with a spinner while requests run; fades 2 s after the last.</summary>
    private void StatusChanged()
    {
        var status = Client.Status;
        if (status.Last is { } fetch)
        {
            _statusText.Text = $"{fetch.Title} [{fetch.Bytes / 1024.0:N1} KiB]";
            ToolTipService.SetToolTip(_statusText, fetch.Url);
        }
        _statusRing.IsActive = status.Active > 0;
        _statusBar.Opacity = 1;
        _statusFade.Stop();
        if (status.Active == 0) _statusFade.Start();
    }
}

/// <summary>The item whose cover is being dragged from a detail pane, in any window.</summary>
internal static class ItemDrag
{
    public static Bib? Current { get; set; }
}
