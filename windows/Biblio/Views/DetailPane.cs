using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Biblio.Views;

/// <summary>The selected item: jacket, title, holds, availability by location, and the full record.</summary>
public sealed class DetailPane : StackPanel
{
    private readonly AccountWindow _window;
    private int _generation;
    public event Action? Closed;
    /// <summary>"You borrowed this…", under the hold controls; empty unless the card borrowed it.</summary>
    private readonly Grid _borrowed = new()
    {
        ColumnSpacing = 8, Visibility = Visibility.Collapsed,
        ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() },
    };
    private Bib? _bib;
    private ulong? _borrowedGeneration;

    public DetailPane(AccountWindow window)
    {
        _window = window;
        Spacing = 16;
    }

    /// <summary>Redraws the "You borrowed this…" line when the index's matches change.</summary>
    public void UpdateBorrowed()
    {
        if (_bib is null || _window.Borrowed is not { } borrowed || borrowed.Generation == _borrowedGeneration) return;
        _borrowedGeneration = borrowed.Generation;
        _borrowed.Children.Clear();
        var match = borrowed.Lookup(_bib);
        _borrowed.Visibility = match is null ? Visibility.Collapsed : Visibility.Visible;
        if (match is null) return;
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        _borrowed.Children.Add(Icons.Make(ItemListView.BorrowedGlyph, 14,
            match.SameFormat ? secondary : (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"]));
        var sentence = new TextBlock { Text = BorrowedText.Sentence(match, _window.Library), Foreground = secondary, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(sentence, 1);
        _borrowed.Children.Add(sentence);
    }

    private ListEntry? _entry;

    /// <summary>The item shown, if any.</summary>
    public ListEntry? Entry => _entry;

    /// <summary>Shows the same item again (a new theme, or a guest signed in).</summary>
    public void Redraw()
    {
        if (_entry is { } entry) Show(entry);
    }

    public void Show(ListEntry entry)
    {
        _entry = entry;
        var generation = ++_generation;
        Children.Clear();
        var bib = entry.Bib;

        var close = new Button { Content = new SymbolIcon(Symbol.Cancel), HorizontalAlignment = HorizontalAlignment.Right };
        ToolTipService.SetToolTip(close, "Close details");
        close.Click += (_, _) => Closed?.Invoke();
        Children.Add(close);

        var image = new Image { Width = 120, Height = 180, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Top };
        if ((bib.JacketLarge ?? bib.JacketSmall) is { } url && Uri.TryCreate(url, UriKind.Absolute, out var uri)) image.Source = new BitmapImage(uri);
        var heading = new StackPanel { Spacing = 4 };
        var titleText = new TextBlock { Text = bib.Title, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], TextWrapping = TextWrapping.Wrap };
        // The cover and title drag onto Holds to place a hold, or onto Search to search for the title.
        Draggable(image, bib.Title, bib);
        Draggable(titleText, bib.Title, bib);
        heading.Children.Add(titleText);
        if (bib.Subtitle is { } sub) heading.Children.Add(new TextBlock { Text = sub, TextWrapping = TextWrapping.Wrap });
        if (bib.PrimaryAuthor is { } author)
        {
            // Authors link to a search for their other works.
            var link = new HyperlinkButton { Content = author, Padding = new Thickness(0) };
            Draggable(link, author, null);
            link.Click += (_, _) =>
            {
                _window.ShowSection(Section.Search);
                _window.ListFor(Section.Search).SearchFor(author);
            };
            heading.Children.Add(link);
        }
        // Format, year, and edition a line each beside the cover, then the availability line and the account's capsule.
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        foreach (var detail in ItemText.Details(bib, _window.Library))
            heading.Children.Add(new TextBlock { Text = detail, Foreground = secondary, TextWrapping = TextWrapping.Wrap });
        if (ItemText.Availability(entry, _window.IsDark) is { } availability) heading.Children.Add(availability);
        if (ItemText.Relationship(entry, _window.IsDark) is { } relationship) heading.Children.Add(relationship);
        var top = new Grid { ColumnSpacing = 16, ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
        top.Children.Add(image);
        Grid.SetColumn(heading, 1);
        top.Children.Add(heading);
        Children.Add(top);

        if (Actions(entry) is { } actions) Children.Add(actions);
        _bib = bib;
        _borrowedGeneration = null;
        Children.Add(_borrowed);
        UpdateBorrowed();
        if (bib.Summary is { } summary) Children.Add(new TextBlock { Text = summary, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });

        var copies = new StackPanel { Spacing = 2 };
        Children.Add(new TextBlock { Text = "Availability by location", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        copies.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Left });
        Children.Add(copies);
        var details = new StackPanel { Spacing = 8 };
        Children.Add(details);
        _ = LoadCopies(bib.Id, copies, generation);
        _ = LoadDetails(bib.Id, details, generation);
    }

    /// <summary>Lets a part of the detail be dragged as text (a search) and, with an item, onto any window's Holds.</summary>
    private static void Draggable(UIElement element, string text, Bib? bib)
    {
        element.CanDrag = true;
        element.DragStarting += (_, e) =>
        {
            e.Data.SetText(text);
            e.Data.RequestedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
            ItemDrag.Current = bib;
        };
        element.DropCompleted += (_, _) => ItemDrag.Current = null;
    }

    private async Task LoadCopies(string id, StackPanel panel, int generation)
    {
        try
        {
            var copies = await _window.Client.AvailabilityAsync(id);
            if (generation != _generation) return;
            panel.Children.Clear();
            if (copies.Count == 0) panel.Children.Add(new TextBlock { Text = "No copies listed." });
            foreach (var c in copies)
            {
                var color = StatusBrushes.Copy(c.Kind, _window.IsDark);
                var detail = string.Join(" · ", new[] { c.Collection, c.CallNumber, c.DueDate is { } d ? $"due {d}" : null }.Where(s => s is not null));
                var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition());
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(Icons.Make(Icons.ForCopy(c.Kind), 14, color));
                var where = new StackPanel { Children = { new TextBlock { Text = c.Branch } } };
                if (detail.Length > 0) where.Children.Add(new TextBlock { Text = detail, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
                Grid.SetColumn(where, 1);
                row.Children.Add(where);
                var label = new TextBlock { Text = c.Status, Foreground = color };
                Grid.SetColumn(label, 2);
                row.Children.Add(label);
                panel.Children.Add(row);
            }
        }
        catch (CoreException e)
        {
            if (generation != _generation) return;
            panel.Children.Clear();
            panel.Children.Add(new TextBlock { Text = e.Message, TextWrapping = TextWrapping.Wrap });
        }
    }

    private async Task LoadDetails(string id, StackPanel panel, int generation)
    {
        List<DetailField> fields;
        try { fields = await _window.Client.DetailsAsync(id); }
        catch (CoreException) { return; }
        if (generation != _generation || fields.Count == 0) return;
        panel.Children.Add(new TextBlock { Text = "Details", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        foreach (var f in fields)
        {
            panel.Children.Add(new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = f.Label, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] },
                    new TextBlock { Text = string.Join("\n", f.Values), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
                },
            });
        }
    }

    /// <summary>Place a hold at a chosen pickup location, or cancel this account's hold.</summary>
    private UIElement? Actions(ListEntry entry)
    {
        // A catalog row only says the account holds the item; the hold itself is in the Holds list.
        var onHold = entry.Hold is not null || entry.AccountStatus?.Kind == "onHold";
        if (onHold)
        {
            if ((entry.Hold ?? _window.HoldFor(entry.Bib.Id)) is not { CanCancel: true } hold) return null;
            // The confirmation is a flyout on the button that asked for it.
            var cancel = new Button { Content = "Cancel Hold" };
            var confirm = new Button { Content = "Cancel Hold", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            var flyout = new Flyout
            {
                Content = new StackPanel
                {
                    Spacing = 12, MaxWidth = 280,
                    Children = { new TextBlock { Text = $"Cancel your hold on “{entry.Bib.Title}”?", TextWrapping = TextWrapping.Wrap }, confirm },
                },
            };
            cancel.Flyout = flyout;
            confirm.Click += async (_, _) =>
            {
                flyout.Hide();
                cancel.IsEnabled = false;
                try
                {
                    var refused = await _window.Client.CancelHoldsAsync([hold]);
                    if (refused.Count > 0) _window.ShowMessage(refused[0].Reason, error: true);
                    else
                    {
                        _window.ShowMessage("Hold canceled.");
                        Closed?.Invoke();
                        _window.HoldsChanged();
                    }
                }
                catch (CoreException e) { _window.ShowMessage(e.Message, error: true); }
                finally { cancel.IsEnabled = true; }
            };
            return cancel;
        }
        if (entry.Checkout is not null) return null;
        if (!entry.Bib.Holdable) return null;
        if (_window.IsGuest)
        {
            var signIn = new Button { Content = "Sign In to Place a Hold…" };
            signIn.Click += async (_, _) => await _window.SignInAsync();
            return signIn;
        }

        var pickup = new ComboBox { Header = "Pick up at", MinWidth = 220 };
        foreach (var loc in _window.Locations)
        {
            var item = new ComboBoxItem { Content = loc.Name, Tag = loc.Id };
            pickup.Items.Add(item);
            if (loc.Id == _window.Patron?.PreferredPickup) pickup.SelectedItem = item;
        }
        var place = new Button { Content = "Place hold", Style = (Style)Application.Current.Resources["AccentButtonStyle"], VerticalAlignment = VerticalAlignment.Bottom };
        place.Click += async (_, _) =>
        {
            place.IsEnabled = false;
            if (!await _window.PlaceHoldAsync(entry.Bib, (pickup.SelectedItem as ComboBoxItem)?.Tag as string)) place.IsEnabled = true;
        };
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { pickup, place } };
    }
}
