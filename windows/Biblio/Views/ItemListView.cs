using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Biblio.Views;

/// <summary>
/// A paged list of search results, new titles, holds, checkouts or history, with the selected
/// item's details beside it. Pages load as the list scrolls near its end.
/// </summary>
public sealed class ItemListView : Grid
{
    private static readonly Dictionary<string, string> NewTitleFilters = new() { ["f_on_order"] = "false" };

    private readonly AccountWindow _window;
    private readonly Section _section;
    private readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _title = new() { Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(24), HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ComboBox _sort = new() { PlaceholderText = "Sort", MinWidth = 160, Visibility = Visibility.Collapsed };
    private readonly ComboBox _format = new() { PlaceholderText = "All formats", MinWidth = 180, Visibility = Visibility.Collapsed };
    private readonly ProgressBar _progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    private readonly DetailPane _detail;
    private readonly ColumnDefinition _detailColumn = new() { Width = new GridLength(0) };
    private readonly AutoSuggestBox? _search;

    private readonly List<ListEntry> _entries = [];
    private Core.ListPage? _page;
    private string _query = "";
    private string? _sortId;
    private string? _formatCode;
    private bool _loading;
    private int _generation;
    private bool _updatingControls;

    public bool HasLoaded => _page is not null;

    public ItemListView(AccountWindow window, Section section)
    {
        _window = window;
        _section = section;
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
        header.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _format, _sort } });
        header.Children.Add(_progress);
        _sort.SelectionChanged += (_, _) =>
        {
            if (_updatingControls || _sort.SelectedItem is not ComboBoxItem { Tag: string id }) return;
            _sortId = id;
            Reload();
        };
        _format.SelectionChanged += (_, _) =>
        {
            if (_updatingControls || _format.SelectedItem is not ComboBoxItem item) return;
            _formatCode = item.Tag as string;
            Reload();
        };

        _list.SelectionChanged += (_, _) =>
        {
            if (_list.SelectedIndex < 0 || _list.SelectedIndex >= _entries.Count) return;
            _detail.Show(_entries[_list.SelectedIndex]);
            _detailColumn.Width = new GridLength(420);
        };
        _list.Loaded += (_, _) =>
        {
            // Infinite scrolling: fetch the next page near the end.
            if (FindScrollViewer(_list) is { } sv)
                sv.ViewChanged += (_, _) => { if (sv.VerticalOffset > sv.ScrollableHeight - 600) LoadMore(); };
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
        UpdateEmpty();
    }

    private static ScrollViewer? FindScrollViewer(DependencyObject root)
    {
        if (root is ScrollViewer sv) return sv;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            if (FindScrollViewer(VisualTreeHelper.GetChild(root, i)) is { } found) return found;
        return null;
    }

    public void SearchFor(string text)
    {
        if (_search is not null) _search.Text = text;
        _query = text;
        _sortId = null;
        _formatCode = null;
        Reload();
    }

    public void LoadIfNeeded()
    {
        if (!HasLoaded && !_loading) Reload();
    }

    public void ReloadIfLoaded()
    {
        if (HasLoaded) Reload();
    }

    public void Reload()
    {
        _generation++;
        _entries.Clear();
        _list.Items.Clear();
        _page = null;
        _loading = false;
        if (_section == Section.Search && string.IsNullOrWhiteSpace(_query)) { UpdateEmpty(); return; }
        _ = Load(1);
    }

    private void LoadMore()
    {
        if (_page is { } p && !_loading && p.Page < p.Pages) _ = Load(p.Page + 1);
    }

    private async Task Load(int page)
    {
        var generation = _generation;
        _loading = true;
        _progress.Visibility = Visibility.Visible;
        try
        {
            var client = _window.Client;
            var result = await (_section switch
            {
                Section.Search => client.SearchAsync(_query, page: page, sort: _sortId, format: _formatCode),
                Section.NewTitles => client.SearchAsync("nw:[0 TO 180]", "bl", NewTitleFilters,
                    page, _sortId ?? "newly_acquired", _formatCode),
                Section.Holds => client.HoldsAsync(page, _sortId),
                Section.Checkouts => client.CheckoutsAsync(page, _sortId),
                _ => client.HistoryAsync(page, _sortId),
            });
            if (generation != _generation) return;
            var first = _page is null;
            _page = result;
            foreach (var entry in result.Entries)
            {
                _entries.Add(entry);
                _list.Items.Add(Row(entry));
            }
            if (first) UpdateControls(result);
            _title.Text = $"{SectionTitle} · {result.Count} items";
            if (_section is Section.Holds or Section.Checkouts) _window.SetCount(_section, result.Count);
        }
        catch (CoreException e)
        {
            if (generation == _generation) _window.ShowMessage(e.Message, error: true);
        }
        finally
        {
            if (generation == _generation)
            {
                _loading = false;
                _progress.Visibility = Visibility.Collapsed;
                UpdateEmpty();
            }
        }
    }

    private string SectionTitle => _section switch
    {
        Section.NewTitles => "New Titles",
        Section.Holds => "Holds",
        Section.Checkouts => "Checked Out",
        Section.History => "Borrowing History",
        _ => "Search",
    };

    private void UpdateEmpty()
    {
        _empty.Visibility = _entries.Count == 0 && !_loading ? Visibility.Visible : Visibility.Collapsed;
        _empty.Text = _section switch
        {
            Section.Search => string.IsNullOrWhiteSpace(_query) ? "Find books, movies, music and more." : "No results.",
            Section.Holds => "Items you place on hold appear here.",
            Section.Checkouts => "Nothing checked out.",
            Section.History => "If borrowing history is on in Account, items you return appear here.",
            _ => "No new titles.",
        };
        if (_section != Section.Search) _title.Text = SectionTitle;
    }

    private void UpdateControls(Core.ListPage page)
    {
        _updatingControls = true;
        _sort.Items.Clear();
        foreach (var id in page.SortOptions ?? [])
        {
            var item = new ComboBoxItem { Content = _window.Library.SortName(id), Tag = id };
            _sort.Items.Add(item);
            if (id == (_sortId ?? page.AppliedSort)) _sort.SelectedItem = item;
        }
        _sort.Visibility = _sort.Items.Count > 1 ? Visibility.Visible : Visibility.Collapsed;

        _format.Items.Clear();
        var formats = page.Facets?.FirstOrDefault(f => f.Id == "FORMAT")?.Values ?? [];
        if (formats.Count > 0)
        {
            _format.Items.Add(new ComboBoxItem { Content = "All formats", Tag = null });
            foreach (var f in formats)
            {
                var item = new ComboBoxItem { Content = $"{_window.Library.FormatName(f.Value)} ({f.Count})", Tag = f.Value };
                _format.Items.Add(item);
                if (f.Value == _formatCode) _format.SelectedItem = item;
            }
        }
        _format.Visibility = formats.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _updatingControls = false;
    }

    private UIElement Row(ListEntry entry)
    {
        var bib = entry.Bib;
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = bib.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextWrapping = TextWrapping.Wrap });
        if (bib.PrimaryAuthor is { } author) text.Children.Add(new TextBlock { Text = author });
        text.Children.Add(new TextBlock
        {
            Text = string.Join(" · ", new[] { _window.Library.FormatName(bib.Format), bib.Year }.Where(s => s is not null)),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        var (status, brush) = StatusLine(entry);
        if (status.Length > 0) text.Children.Add(new TextBlock { Text = status, Foreground = brush });
        var image = new Image { Width = 48, Height = 72, Stretch = Stretch.Uniform };
        if (bib.JacketSmall is { } url && Uri.TryCreate(url, UriKind.Absolute, out var uri)) image.Source = new BitmapImage(uri);
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(0, 8, 0, 8), Children = { image, text } };
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
        string? counts = b.TotalCopies > 0 ? $"{b.HeldCopies} holds on {b.TotalCopies} copies" : null;
        return (string.Join(" · ", new[] { label, counts }.Where(x => x is not null)), StatusBrushes.Availability(b.Status));
    }
}
