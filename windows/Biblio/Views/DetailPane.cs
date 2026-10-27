using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Biblio.Views;

/// <summary>The selected item: jacket, title, holds, availability by location and the full record.</summary>
public sealed class DetailPane : StackPanel
{
    private readonly AccountWindow _window;
    private int _generation;
    public event Action? Closed;

    public DetailPane(AccountWindow window)
    {
        _window = window;
        Spacing = 16;
    }

    public void Show(ListEntry entry)
    {
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
        heading.Children.Add(new TextBlock { Text = bib.Title, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], TextWrapping = TextWrapping.Wrap });
        if (bib.Subtitle is { } sub) heading.Children.Add(new TextBlock { Text = sub, TextWrapping = TextWrapping.Wrap });
        if (bib.PrimaryAuthor is { } author)
        {
            // Authors link to a search for their other works.
            var link = new HyperlinkButton { Content = author, Padding = new Thickness(0) };
            link.Click += (_, _) =>
            {
                _window.ShowSection(Section.Search);
                _window.ListFor(Section.Search).SearchFor(author);
            };
            heading.Children.Add(link);
        }
        heading.Children.Add(new TextBlock
        {
            Text = string.Join(" · ", new[] { _window.Library.FormatName(bib.Format), bib.Year }.Where(s => s is not null)),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        });
        var (status, brush) = ItemListView.StatusLine(entry);
        if (status.Length > 0) heading.Children.Add(new TextBlock { Text = status, Foreground = brush, TextWrapping = TextWrapping.Wrap });
        var top = new Grid { ColumnSpacing = 16, ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
        top.Children.Add(image);
        Grid.SetColumn(heading, 1);
        top.Children.Add(heading);
        Children.Add(top);

        if (Actions(entry) is { } actions) Children.Add(actions);
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

    private async Task LoadCopies(string id, StackPanel panel, int generation)
    {
        try
        {
            var copies = await _window.Client.CallAsync<List<CopyAvailability>>("availability", new { metadataId = id });
            if (generation != _generation) return;
            panel.Children.Clear();
            if (copies.Count == 0) panel.Children.Add(new TextBlock { Text = "No copies listed." });
            foreach (var c in copies)
            {
                var color = StatusBrushes.Copy(c.Kind);
                var detail = string.Join(" · ", new[] { c.Collection, c.CallNumber, c.DueDate is { } d ? $"due {d}" : null }.Where(s => s is not null));
                var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition());
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.Children.Add(new FontIcon { Glyph = Glyph(c.Kind), Foreground = color, FontSize = 14 });
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

    /// <summary>Segoe Fluent Icons glyphs for each copy status.</summary>
    private static string Glyph(string kind) => kind switch
    {
        "available" => "", // CheckMark
        "onOrder" => "",   // Package
        "out" => "",       // Recent
        "held" => "",      // Shop
        "transit" => "",   // Switch
        "repair" => "",    // Repair
        "missing" or "claimsReturned" => "", // Unknown
        _ => "",           // StatusCircle
    };

    private async Task LoadDetails(string id, StackPanel panel, int generation)
    {
        List<DetailField> fields;
        try { fields = await _window.Client.CallAsync<List<DetailField>>("details", new { metadataId = id }); }
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
        if (entry.Hold is { } hold)
        {
            if (!hold.CanCancel) return null;
            var cancel = new Button { Content = "Cancel hold" };
            cancel.Click += async (_, _) =>
            {
                var confirm = new ContentDialog
                {
                    XamlRoot = XamlRoot, Title = $"Cancel your hold on “{entry.Bib.Title}”?",
                    PrimaryButtonText = "Cancel hold", CloseButtonText = "Keep hold", DefaultButton = ContentDialogButton.Close,
                };
                if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
                cancel.IsEnabled = false;
                try
                {
                    var result = await _window.Client.CallAsync<CancelResult>("cancelHolds", new { holds = new[] { new { id = hold.Id, metadataId = hold.MetadataId } } });
                    if (result.Refused is { Count: > 0 } refused) _window.ShowMessage(refused[0].Reason, error: true);
                    else
                    {
                        _window.ShowMessage("Hold cancelled.");
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
        if (_window.IsGuest) return new TextBlock { Text = "Sign in to place holds." };
        if (!entry.Bib.Holdable) return null;

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
            try
            {
                await _window.Client.CallAsync<bool>("placeHold", new
                {
                    metadataId = entry.Bib.Id, materialType = entry.Bib.MaterialType,
                    pickupBranch = (pickup.SelectedItem as ComboBoxItem)?.Tag as string,
                });
                _window.ShowMessage($"Hold placed on “{entry.Bib.Title}”.");
                _window.HoldsChanged();
            }
            catch (CoreException e)
            {
                _window.ShowMessage(e.Message, error: true);
                place.IsEnabled = true;
            }
        };
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { pickup, place } };
    }
}
