using System.Collections.ObjectModel;
using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Biblio.Views;

/// <summary>
/// A paged list of search results, new titles, holds, checkouts or history, with the selected
/// item's details beside it.
///
/// Paging, sorting and filtering are libbiblio's item list (<see cref="CoreList"/>), shared with the
/// other apps: it says which pages to fetch and which rows to show, and this view fetches those pages
/// and keeps their entries. Once the first page reports the total, every item not fetched yet is a
/// placeholder row, so the scroll bar has its final length; a page is fetched when its placeholders
/// stay on screen briefly. Client sorts and local filters fetch the remaining pages in the background.
/// </summary>
public sealed class ItemListView : Grid, IDisposable
{
    private static readonly Dictionary<string, string> NewTitleFilters = new() { ["f_on_order"] = "false" };

    /// <summary>The sort menu's client-side entries; the server's own are its sort ids.</summary>
    private const string SortPeopleWaiting = "~people";
    private const string SortTitle = "~title";

    /// <summary>How long placeholders must stay on screen before their page is fetched.</summary>
    private static readonly TimeSpan PlaceholderDwell = TimeSpan.FromMilliseconds(300);

    /// <summary>
    /// A displayed row: a fetched item, or a stand-in for the item at a server position. Borrowed is the
    /// borrowed-before index's generation it was drawn with, so its mark is redrawn when matches change.
    /// </summary>
    private sealed record RowModel(string Key, ListEntry? Entry, long Position, ulong Borrowed);

    private readonly AccountWindow _window;
    private readonly Section _section;
    private readonly CoreList _core;
    private readonly ObservableCollection<RowModel> _rows = [];
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _title = new() { Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(24), HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ComboBox _sort = new() { PlaceholderText = "Sort", MinWidth = 160, Visibility = Visibility.Collapsed };
    private readonly ComboBox _format = new() { PlaceholderText = "All formats", MinWidth = 180, Visibility = Visibility.Collapsed };
    private readonly ToggleButton[] _holdFilters = [new(), new(), new()];
    private readonly ToggleButton _notBorrowed = new()
    {
        Visibility = Visibility.Collapsed,
        Content = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8,
            Children = { new FontIcon { Glyph = BorrowedGlyph, FontSize = 14 }, new TextBlock { Text = "Not Borrowed" } },
        },
    };
    private readonly ProgressBar _progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    private readonly DetailPane _detail;
    private readonly ColumnDefinition _detailColumn = new() { Width = new GridLength(0) };
    private readonly AutoSuggestBox? _search;

    /// <summary>Fetched entries by id; the core list knows their positions.</summary>
    private readonly Dictionary<string, ListEntry> _entries = [];
    private List<string> _serverSorts = [];
    private List<FacetValue> _facets = [];
    private string _query = "";
    private string? _sortId;
    private string? _appliedSort;
    private string? _formatCode;
    private string _sortSignature = "";
    private string _formatSignature = "";
    private bool _background;
    private bool _disposed;
    private bool _updatingControls;
    private CancellationTokenSource? _backgroundCts;
    private CancellationTokenSource? _dwellCts;

    private bool IsCatalog => _section is Section.Search or Section.NewTitles;
    /// <summary>Catalog and hold rows say what the patron borrowed before; checkouts and history don't.</summary>
    private bool ShowsBorrowed => _window.Borrowed is not null && (IsCatalog || _section == Section.Holds);
    /// <summary>The generation "Not Borrowed" was last set with.</summary>
    private ulong _notBorrowedGeneration;

    /// <summary>Segoe Fluent Icons' History, for "borrowed before".</summary>
    public const string BorrowedGlyph = "";
    private static long Now => Environment.TickCount64;

    public bool HasLoaded => !_disposed && _core.GetState().Loaded;

    public ItemListView(AccountWindow window, Section section)
    {
        _window = window;
        _section = section;
        _core = new CoreList(section switch
        {
            Section.Holds => CoreList.Kind.Holds,
            Section.Checkouts => CoreList.Kind.Checkouts,
            Section.History => CoreList.Kind.History,
            _ => CoreList.Kind.Search,
        });
        _detail = new DetailPane(window);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(_detailColumn);

        var header = new StackPanel { Spacing = 8, Padding = new Thickness(24, 12, 24, 8) };
        if (section == Section.Search)
        {
            _search = new AutoSuggestBox
            {
                PlaceholderText = $"Search {window.Library.DisplayName}", QueryIcon = new SymbolIcon(Symbol.Find), MaxWidth = 560,
                HorizontalAlignment = HorizontalAlignment.Left, MinWidth = 320,
            };
            _search.QuerySubmitted += (_, args) => SearchFor(args.QueryText);
            header.Children.Add(_search);
        }
        else
        {
            header.Children.Add(_title);
        }
        var refresh = new Button { Content = new SymbolIcon(Symbol.Refresh) };
        ToolTipService.SetToolTip(refresh, "Refresh (Ctrl+R)");
        refresh.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = Windows.System.VirtualKey.R, Modifiers = Windows.System.VirtualKeyModifiers.Control });
        refresh.Click += async (_, _) => await RefreshAsync();
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _format, _sort, refresh } };
        header.Children.Add(controls);
        _notBorrowed.Click += (_, _) => SetNotBorrowed();
        ToolTipService.SetToolTip(_notBorrowed, "Hide what you borrowed before in the same format");
        if (section == Section.Holds)
        {
            // "Ready", "Not Ready" and "On Order", each with a count; at most one is on.
            var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            foreach (var button in _holdFilters)
            {
                button.Click += (_, _) => OnHoldFilter(button);
                filters.Children.Add(button);
            }
            filters.Children.Add(_notBorrowed);
            header.Children.Add(filters);
        }
        else if (IsCatalog)
        {
            controls.Children.Insert(1, _notBorrowed);
        }
        header.Children.Add(_progress);
        _sort.SelectionChanged += (_, _) =>
        {
            if (_updatingControls || _sort.SelectedItem is not ComboBoxItem { Tag: string id }) return;
            SetSort(id);
        };
        _format.SelectionChanged += (_, _) =>
        {
            if (_updatingControls || _format.SelectedItem is not ComboBoxItem item) return;
            SetFormat(item.Tag as string);
        };

        // Rows are filled in as the list view realizes and recycles its containers.
        _list.ItemsSource = _rows;
        _list.ItemTemplate = (DataTemplate)XamlReader.Load(
            "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Grid/></DataTemplate>");
        var container = new Style(typeof(ListViewItem));
        container.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        _list.ItemContainerStyle = container;
        _list.ContainerContentChanging += OnContainerContentChanging;
        _list.SelectionChanged += (_, _) =>
        {
            if (_list.SelectedItem is not RowModel { Entry: { } entry }) return;
            _detail.Show(entry);
            _detailColumn.Width = new GridLength(420);
        };

        var left = new Grid { RowDefinitions = { new RowDefinition { Height = GridLength.Auto }, new RowDefinition() } };
        left.Children.Add(header);
        left.Children.Add(LauncherWindow.WithRow(_list, 1));
        left.Children.Add(LauncherWindow.WithRow(_empty, 1));
        Children.Add(left);
        var detail = new ScrollViewer { Content = _detail, Padding = new Thickness(16) };
        SetColumn(detail, 1);
        Children.Add(detail);
        _detail.Closed += () => { _detailColumn.Width = new GridLength(0); _list.SelectedIndex = -1; };
        Sync();
    }

    /// <summary>The list has no more use: its core list is freed, and pages still in flight are dropped.</summary>
    public void Dispose()
    {
        _disposed = true;
        _backgroundCts?.Cancel();
        _dwellCts?.Cancel();
        _core.Dispose();
    }

    // MARK: Loading

    public void SearchFor(string text)
    {
        if (_search is not null) _search.Text = text;
        _query = text;
        _sortId = null;
        _appliedSort = null;
        _formatCode = null;
        _core.SetSort(CoreList.Sort.Server);
        _core.SetFormat(null);
        Reload(keepContent: false);
    }

    /// <summary>Loads a list that hasn't been fetched yet, or refetches one older than 15 minutes.</summary>
    public void LoadIfNeeded()
    {
        if (_disposed) return;
        var state = _core.GetState();
        if (state.Loading) return;
        if (!state.Loaded) Reload(keepContent: false);
        else if (_core.IsStale(Now)) Reload(keepContent: true);
    }

    public void ReloadIfLoaded()
    {
        if (HasLoaded) Reload();
    }

    /// <summary>Starts again from the first page; keeping content leaves the rows, stale, until it arrives.</summary>
    public void Reload(bool keepContent = true)
    {
        if (_disposed) return;
        _background = false;
        _backgroundCts?.Cancel();
        _dwellCts?.Cancel();
        if (_section == Section.Search && string.IsNullOrWhiteSpace(_query))
        {
            _core.Clear();
            _entries.Clear();
            _facets = [];
            Sync();
            return;
        }
        var generation = _core.Reload(keepContent);
        if (!keepContent) _entries.Clear();
        Sync();
        _ = FetchNow(1, generation);
    }

    /// <summary>
    /// Refresh button or Ctrl+R. Account lists start a fresh session first: the gateway can keep serving
    /// one session a wrong list (checkouts reported empty), and a new session may not.
    /// </summary>
    public async Task RefreshAsync()
    {
        if (_disposed) return;
        if (IsCatalog) { Reload(); return; }
        _core.BeginRefresh();
        Sync();
        // Borrowing history syncs again too (or is forgotten, if the library turned it off).
        try { _window.SignedIn(await _window.Client.LoginAsync(force: true)); }
        catch (CoreException) { /* The reload below reports whatever is still wrong. */ }
        catch (ObjectDisposedException) { return; }
        Reload();
    }

    private Task<ListPage> FetchAsync(int page)
    {
        var client = _window.Client;
        var server = _sortId is { } s && !s.StartsWith('~') ? s : _section == Section.NewTitles ? "newly_acquired" : null;
        return _section switch
        {
            Section.Search => client.SearchAsync(_query, page: page, sort: server, format: _formatCode),
            Section.NewTitles => client.SearchAsync("nw:[0 TO 180]", "bl", NewTitleFilters, page, server, _formatCode),
            Section.Holds => client.HoldsAsync(page, server),
            Section.Checkouts => client.CheckoutsAsync(page, server),
            _ => client.HistoryAsync(page, server),
        };
    }

    /// <summary>Fetches a page the core list requested (it is in flight there); false if that failed.</summary>
    private async Task<bool> FetchNow(int page, ulong generation)
    {
        try
        {
            var result = await FetchAsync(page);
            if (_disposed) return false;
            Apply(result, page, generation);
            return true;
        }
        catch (CoreException e)
        {
            if (!_disposed && _core.Fail(generation, page))
            {
                _window.ShowMessage(e.Message, error: true);
                Sync();
            }
            return false;
        }
        catch (ObjectDisposedException)
        {
            return false;
        }
    }

    private void Apply(ListPage result, int page, ulong generation)
    {
        if (generation != _core.Generation) return;
        // The first page of a refresh replaces the stale entries.
        if (page == 1 && _core.GetState().Refreshing) _entries.Clear();
        // An item that moved between pages while fetching keeps its first position.
        foreach (var e in result.Entries) _entries.TryAdd(e.Id, e);
        _core.Apply(generation, result, Now);
        if (page == 1 || result.Facets is { Count: > 0 }) _facets = result.Facets?.FirstOrDefault(f => f.Id == "FORMAT")?.Values ?? [];
        if (result.SortOptions is { Count: > 0 }) _serverSorts = result.SortOptions;
        if (_sortId is null) _appliedSort = result.AppliedSort;
        Sync();
        if (page == 1 && _core.WantsAllPages) _ = StartBackground();
    }

    /// <summary>
    /// Fetches the remaining pages, one at a time, for client sorts, local filters, and holds (whose
    /// filter counts need every hold).
    /// </summary>
    private async Task StartBackground()
    {
        if (_disposed || !_core.BeginBackground()) return;
        var generation = _core.Generation;
        _background = true;
        var cts = _backgroundCts = new CancellationTokenSource();
        Sync();
        try
        {
            while (!cts.IsCancellationRequested && !_disposed && generation == _core.Generation)
            {
                var page = _core.NextBackgroundPage();
                if (page <= 0) break;
                if (!await FetchNow(page, generation))
                {
                    if (!_disposed) _core.EndBackground();
                    break;
                }
            }
        }
        finally
        {
            if (!_disposed && generation == _core.Generation)
            {
                _background = false;
                Sync();
            }
        }
    }

    // MARK: Scrolling

    private void OnContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (_disposed) return;
        var container = args.ItemContainer;
        // A container that showed a placeholder is no longer showing it.
        if (container.Tag is long shown)
        {
            _core.PlaceholderDisappeared(shown);
            container.Tag = null;
        }
        if (args.InRecycleQueue || args.Item is not RowModel row || container.ContentTemplateRoot is not Grid root) return;
        root.Children.Clear();
        var refreshing = _core.GetState().Refreshing;
        if (row.Entry is null)
        {
            root.Children.Add(PlaceholderRow());
            if (refreshing) return;
            container.Tag = row.Position;
            _core.PlaceholderAppeared(row.Position);
            ScheduleDwell();
            return;
        }
        root.Children.Add(Row(row.Entry));
        if (refreshing) return;
        // Nearing the placeholders after this item: prefetch their page.
        var page = _core.ItemAppeared(row.Position);
        if (page > 0) _ = FetchNow(page, _core.Generation);
    }

    /// <summary>Placeholders that stay in view for a moment get their page fetched.</summary>
    private void ScheduleDwell()
    {
        _dwellCts?.Cancel();
        var cts = _dwellCts = new CancellationTokenSource();
        _ = Dwell(cts.Token);
    }

    private async Task Dwell(CancellationToken token)
    {
        try { await Task.Delay(PlaceholderDwell, token); }
        catch (TaskCanceledException) { return; }
        if (_disposed) return;
        var generation = _core.Generation;
        foreach (var page in _core.TakeVisibleRequests()) _ = FetchNow(page, generation);
    }

    // MARK: Filtering and sorting

    private void SetSort(string id)
    {
        _sortId = id;
        if (id is SortPeopleWaiting or SortTitle)
        {
            _core.SetSort(id == SortTitle ? CoreList.Sort.Title : CoreList.Sort.PeopleWaiting);
            Sync();
            _ = StartBackground();
            return;
        }
        _core.SetSort(CoreList.Sort.Server);
        Reload();
    }

    private void SetFormat(string? code)
    {
        _formatCode = code;
        // Searches ask the server for the format, and filter refined ones (4K filed as Blu-ray) locally too.
        _core.SetFormat(code);
        if (IsCatalog) { Reload(); return; }
        Sync();
        if (_core.NeedsAllPages) _ = StartBackground();
    }

    /// <summary>"Not Borrowed" turned on or off, or the index's matches changed while it's on.</summary>
    private void SetNotBorrowed()
    {
        if (_updatingControls || _window.Borrowed is not { } borrowed) return;
        _notBorrowedGeneration = borrowed.Generation;
        _core.SetNotBorrowed(_notBorrowed.IsChecked == true ? [borrowed] : []);
        Sync();
        if (_core.NeedsAllPages) _ = StartBackground();
    }

    /// <summary>The borrowed-before index's progress or matches changed: marks, and "Not Borrowed" if it's on.</summary>
    public void BorrowedChanged()
    {
        if (_disposed) return;
        _detail.UpdateBorrowed();
        if (!ShowsBorrowed) return;
        if (_notBorrowed.IsChecked == true && _window.Borrowed?.Generation != _notBorrowedGeneration) SetNotBorrowed();
        else Sync();
    }

    private void OnHoldFilter(ToggleButton clicked)
    {
        if (_updatingControls) return;
        // At most one filter is on: turning one on turns the others off.
        _updatingControls = true;
        foreach (var b in _holdFilters) if (b != clicked) b.IsChecked = false;
        _updatingControls = false;
        var index = Array.IndexOf(_holdFilters, clicked);
        _core.SetHoldFilter(clicked.IsChecked == true
            ? index switch { 0 => CoreList.HoldFilter.Ready, 1 => CoreList.HoldFilter.NotReady, _ => CoreList.HoldFilter.OnOrder }
            : CoreList.HoldFilter.None);
        Sync();
        if (_core.NeedsAllPages) _ = StartBackground();
    }

    /// <summary>Brings the rows, controls, and badges up to date with the core list after any change.</summary>
    private void Sync()
    {
        if (_disposed) return;
        var state = _core.GetState();
        var models = new List<RowModel>();
        var borrowed = ShowsBorrowed ? _window.Borrowed?.Generation ?? 0 : 0;
        foreach (var row in _core.Rows())
        {
            if (row.Id is null) models.Add(new RowModel($"placeholder-{row.Position}", null, row.Position, 0));
            else if (_entries.TryGetValue(row.Id, out var entry)) models.Add(new RowModel(row.Id, entry, row.Position, borrowed));
        }
        Replace(models);
        _progress.Visibility = state.Loading || _background || state.Refreshing ? Visibility.Visible : Visibility.Collapsed;
        _list.Opacity = state.Refreshing ? 0.5 : 1;
        if (state.Loaded && _section is Section.Holds or Section.Checkouts) _window.SetCount(_section, (int)state.Total);
        UpdateControls();
        UpdateEmpty(state);
    }

    private static bool Same(RowModel a, RowModel b) =>
        a.Key == b.Key && a.Position == b.Position && ReferenceEquals(a.Entry, b.Entry) && a.Borrowed == b.Borrowed;

    /// <summary>Changes only the rows that differ, so the scroll position holds.</summary>
    private void Replace(List<RowModel> models)
    {
        var prefix = 0;
        while (prefix < _rows.Count && prefix < models.Count && Same(_rows[prefix], models[prefix])) prefix++;
        var suffix = 0;
        while (suffix < _rows.Count - prefix && suffix < models.Count - prefix &&
               Same(_rows[_rows.Count - 1 - suffix], models[models.Count - 1 - suffix])) suffix++;
        var removals = _rows.Count - prefix - suffix;
        var additions = models.Count - prefix - suffix;
        var common = Math.Min(removals, additions);
        for (var i = 0; i < common; i++) _rows[prefix + i] = models[prefix + i];
        for (var i = common; i < removals; i++) _rows.RemoveAt(prefix + common);
        for (var i = common; i < additions; i++) _rows.Insert(prefix + i, models[prefix + i]);
    }

    private string SectionTitle => _section switch
    {
        Section.NewTitles => "New Titles",
        Section.Holds => "Holds",
        Section.Checkouts => "Checked Out",
        Section.History => "Borrowing History",
        _ => "Search",
    };

    private void UpdateEmpty(CoreList.State state)
    {
        _empty.Visibility = _rows.Count == 0 && !state.Loading && !state.Refreshing ? Visibility.Visible : Visibility.Collapsed;
        _empty.Text = _section switch
        {
            Section.Search => string.IsNullOrWhiteSpace(_query) ? "Find books, movies, music, and more." : "No results.",
            Section.Holds => "Items you place on hold appear here.",
            Section.Checkouts => "Nothing checked out.",
            Section.History => "If borrowing history is on in Account, items you return appear here.",
            _ => "No new titles.",
        };
        if (_section != Section.Search) _title.Text = SectionTitle;
    }

    /// <summary>The sort menu, format menu, and hold filter buttons; menus are rebuilt only when their choices change.</summary>
    private void UpdateControls()
    {
        _updatingControls = true;
        try
        {
            var sorts = new List<string>(_serverSorts) { SortPeopleWaiting };
            if (!_serverSorts.Contains("title")) sorts.Add(SortTitle);
            // The chosen entries stay out of the signatures: a menu cleared from its own SelectionChanged
            // (a choice that syncs) brings down the app.
            var sortSignature = string.Join('|', sorts);
            if (_serverSorts.Count > 0 && sortSignature != _sortSignature)
            {
                _sortSignature = sortSignature;
                _sort.Items.Clear();
                foreach (var id in sorts)
                {
                    _sort.Items.Add(new ComboBoxItem
                    {
                        Content = id switch { SortPeopleWaiting => "People waiting", SortTitle => "Title", _ => _window.Library.SortName(id) },
                        Tag = id,
                    });
                }
            }
            Select(_sort, _sortId ?? _appliedSort);
            _sort.Visibility = _serverSorts.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

            var formats = IsCatalog ? _facets : _core.Formats();
            var formatSignature = string.Join('|', formats.Select(f => $"{f.Value}:{f.Count}"));
            if (formatSignature != _formatSignature)
            {
                _formatSignature = formatSignature;
                _format.Items.Clear();
                if (formats.Count > 0)
                {
                    _format.Items.Add(new ComboBoxItem { Content = "All formats", Tag = null });
                    foreach (var f in formats)
                    {
                        // A count of -1 is unknown: a refined format the search filters locally.
                        var name = _window.Library.FormatName(f.Value);
                        _format.Items.Add(new ComboBoxItem { Content = f.Count < 0 ? name : $"{name} ({f.Count})", Tag = f.Value });
                    }
                }
            }
            Select(_format, _formatCode);
            _format.Visibility = formats.Count > 0 || _formatCode is not null ? Visibility.Visible : Visibility.Collapsed;

            // Offered once the whole history is read, so it never hides less than it says.
            _notBorrowed.Visibility = ShowsBorrowed && (_window.Borrowed is { IsComplete: true } || _notBorrowed.IsChecked == true)
                ? Visibility.Visible : Visibility.Collapsed;

            if (_section == Section.Holds)
            {
                string[] names = ["Ready", "Not ready", "On order"];
                CoreList.HoldFilter[] filters = [CoreList.HoldFilter.Ready, CoreList.HoldFilter.NotReady, CoreList.HoldFilter.OnOrder];
                for (var i = 0; i < _holdFilters.Length; i++) _holdFilters[i].Content = $"{names[i]} ({_core.HoldCount(filters[i])})";
            }
        }
        finally { _updatingControls = false; }
    }

    /// <summary>Selects the menu entry tagged with this id, changing nothing if it's already chosen; none for null.</summary>
    private static void Select(ComboBox menu, string? id)
    {
        var current = (menu.SelectedItem as ComboBoxItem)?.Tag as string;
        if (current == id) return;
        if (id is null) { menu.SelectedIndex = -1; return; }
        if (menu.Items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag as string == id) is { } item) menu.SelectedItem = item;
    }

    // MARK: Rows

    /// <summary>Stands in for an item that hasn't been fetched yet.</summary>
    private static UIElement PlaceholderRow() => new Border { Height = 96 };

    private UIElement Row(ListEntry entry)
    {
        var bib = entry.Bib;
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = bib.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextWrapping = TextWrapping.Wrap });
        if (bib.PrimaryAuthor is { } author) text.Children.Add(new TextBlock { Text = author });
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var details = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        details.Children.Add(new TextBlock
        {
            Text = string.Join(" · ", new[] { _window.Library.FormatName(bib.Format), bib.Year }.Where(s => s is not null)),
            Foreground = secondary,
        });
        if (ShowsBorrowed && _window.Borrowed?.Lookup(bib) is { } match) details.Children.Add(BorrowedMark(match, _window.Library));
        text.Children.Add(details);
        var (status, brush) = StatusLine(entry);
        if (status.Length > 0) text.Children.Add(new TextBlock { Text = status, Foreground = brush });
        var image = new Image { Width = 48, Height = 72, Stretch = Stretch.Uniform };
        if (bib.JacketSmall is { } url && Uri.TryCreate(url, UriKind.Absolute, out var uri)) image.Source = new BitmapImage(uri);
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(0, 8, 0, 8), Children = { image, text } };
    }

    /// <summary>A row's quiet "borrowed before" mark, fainter for the same work in another format.</summary>
    private static UIElement BorrowedMark(BorrowedIndex.Match match, LibraryInfo library)
    {
        var text = BorrowedText.Short(match, library);
        var mark = new FontIcon
        {
            Glyph = BorrowedGlyph, FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources[match.SameFormat ? "TextFillColorSecondaryBrush" : "TextFillColorTertiaryBrush"],
        };
        ToolTipService.SetToolTip(mark, text);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(mark, text);
        return mark;
    }

    public static (string, Brush) StatusLine(ListEntry entry)
    {
        var s = entry.AccountStatus;
        if (s?.Kind == "checkedOut") return (s.Due is { } d ? $"Checked out · due {d}" : "Checked out", StatusBrushes.Copy("held"));
        if (s is { Ready: true }) return ("Ready for pickup", StatusBrushes.Copy("available"));
        if (s is not null) return (s.Position is { } p ? $"On hold · #{p}" : "On hold", StatusBrushes.Copy("transit"));
        if (entry.History is { } h) return (h.ReturnedDate is { } r ? $"Returned {r}" : "", StatusBrushes.Copy("withdrawn"));
        var b = entry.Bib;
        string? label = b.Status switch { "AVAILABLE" => "Available", "ON_ORDER" => "On order", "UNAVAILABLE" or "NOT_AVAILABLE" => "All copies in use", _ => null };
        string copies = b.TotalCopies == 1 ? "1 copy" : $"{b.TotalCopies} copies";
        string holds = b.HeldCopies == 1 ? "1 hold" : $"{b.HeldCopies} holds";
        // Only what's there to say: no holds, just the copies; no copies yet, just the holds.
        string? counts = b.HeldCopies == 0 && b.TotalCopies == 0 ? null
            : b.HeldCopies == 0 ? copies : b.TotalCopies == 0 ? holds : $"{holds} on {copies}";
        return (string.Join(" · ", new[] { label, counts }.Where(x => x is not null)), StatusBrushes.Availability(b.Status));
    }
}
