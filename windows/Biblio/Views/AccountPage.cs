using Biblio.Core;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Biblio.Views;

/// <summary>Library card, email, password, pickup location, language, and borrowing history, as Fluent settings cards.</summary>
public sealed class AccountPage : UserControl
{
    private readonly AccountWindow _window;
    // ScrollViewer is sealed, so the page wraps one.
    private readonly ScrollViewer _scroll = new() { Padding = new Thickness(24, 12, 24, 24) };
    private bool _filling;
    // "Borrowed before": updated in place as the index syncs.
    private SettingsCard? _borrowedCard;
    private Button? _refreshBorrowed;
    private ProgressBar? _borrowedProgress;
    private TextBlock? _borrowedStatus;

    public AccountPage(AccountWindow window)
    {
        _window = window;
        Content = _scroll;
    }

    public void Refresh()
    {
        var patron = _window.Patron;
        var stack = new StackPanel { Spacing = 4, MaxWidth = 900 };
        _scroll.Content = stack;
        stack.Children.Add(new TextBlock { Text = "Account", Style = (Style)Application.Current.Resources["TitleTextBlockStyle"], Margin = new Thickness(0, 0, 0, 12) });
        if (patron is null)
        {
            stack.Children.Add(new ProgressRing { IsActive = true });
            return;
        }
        _filling = true;

        stack.Children.Add(new SettingsCard { Header = "Name", Description = patron.Name, HeaderIcon = new SymbolIcon(Symbol.Contact) });
        if (patron.Barcode is { } barcode) stack.Children.Add(LibraryCard(barcode));

        var email = new TextBox { Text = patron.Email ?? "", MinWidth = 260, InputScope = Scope(Microsoft.UI.Xaml.Input.InputScopeNameValue.EmailSmtpAddress) };
        var update = new Button { Content = "Update" };
        update.Click += (_, _) =>
        {
            if (!email.Text.Contains('@')) { _window.ShowMessage("Enter a valid email address.", error: true); return; }
            var address = email.Text;
            _ = Save(c => c.ChangeEmailAsync(address), "Email address updated.");
        };
        stack.Children.Add(new SettingsCard
        {
            Header = "Email", HeaderIcon = new SymbolIcon(Symbol.Mail),
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { email, update } },
        });

        var current = new PasswordBox { PlaceholderText = "Current password" };
        var newPassword = new PasswordBox { PlaceholderText = "New password" };
        var confirm = new PasswordBox { PlaceholderText = "Confirm new password" };
        var change = new Button { Content = "Change password" };
        change.Click += async (_, _) =>
        {
            if (current.Password.Length == 0 || newPassword.Password.Length == 0) return;
            if (newPassword.Password != confirm.Password) { _window.ShowMessage("The new passwords don’t match.", error: true); return; }
            var pw = newPassword.Password;
            var old = current.Password;
            if (await Save(c => c.ChangePasswordAsync(old, pw), "Password changed."))
            {
                // Keep the Credential Locker in step so automatic sign-in still works.
                LibraryStore.Shared.SetPassword(_window.Library.Subdomain, _window.Username, pw);
                current.Password = newPassword.Password = confirm.Password = "";
            }
        };
        stack.Children.Add(new SettingsExpander
        {
            Header = "Password", HeaderIcon = new SymbolIcon(Symbol.Permissions),
            Items =
            {
                new SettingsCard { Content = current, Header = "Current" },
                new SettingsCard { Content = newPassword, Header = "New" },
                new SettingsCard { Content = confirm, Header = "Confirm" },
                new SettingsCard { Content = change },
            },
        });

        var pickup = new ComboBox { MinWidth = 220 };
        foreach (var loc in _window.Locations)
        {
            var item = new ComboBoxItem { Content = loc.Name, Tag = loc.Id };
            pickup.Items.Add(item);
            if (loc.Id == patron.PreferredPickup) pickup.SelectedItem = item;
        }
        pickup.SelectionChanged += (_, _) =>
        {
            if (!_filling && (pickup.SelectedItem as ComboBoxItem)?.Tag is string id)
                _ = Save(c => c.SetPickupAsync(id), "Default pickup location saved.");
        };
        stack.Children.Add(new SettingsCard
        {
            Header = "Pickup location", Description = "Used for new holds unless you choose another location when placing one.",
            HeaderIcon = new SymbolIcon(Symbol.Home), Content = pickup,
        });

        var language = new ComboBox { MinWidth = 220 };
        foreach (var code in _window.Library.Languages ?? [])
        {
            var name = _window.Library.Labels?.GetValueOrDefault($"LANGUAGE_NAME.{code}") ?? code;
            var item = new ComboBoxItem { Content = name, Tag = code };
            language.Items.Add(item);
            if (code == patron.Language) language.SelectedItem = item;
        }
        language.SelectionChanged += async (_, _) =>
        {
            if (_filling || (language.SelectedItem as ComboBoxItem)?.Tag is not string code) return;
            if (await Save(c => c.SetLanguageAsync(code), "Language changed."))
                foreach (var s in new[] { Section.Search, Section.NewTitles }) _window.ListFor(s).ReloadIfLoaded();
        };
        // The account's language is its own preference, never set automatically; this offers the closest to Windows'.
        var system = ClosestToSystem(_window.Library.Languages ?? []);
        var useSystem = new Button { Content = "Use System Language" };
        if (system is null || system == patron.Language) useSystem.Visibility = Visibility.Collapsed;
        useSystem.Click += (_, _) =>
        {
            if (system is { } code && language.Items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag as string == code) is { } item)
                language.SelectedItem = item;
        };
        stack.Children.Add(new SettingsCard
        {
            Header = "Language", HeaderIcon = new SymbolIcon(Symbol.Globe),
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { language, useSystem } },
        });

        if (patron.BorrowingHistoryEnabled is { } enabled)
        {
            var toggle = new ToggleSwitch { IsOn = enabled };
            toggle.Toggled += async (_, _) =>
            {
                if (_filling) return;
                if (toggle.IsOn)
                {
                    if (await Save(c => c.SetBorrowingHistoryAsync(true), "Borrowing history turned on.")) _window.Borrowed?.Sync(_window.Client);
                    return;
                }
                // Turning history off can delete it, so it asks first.
                var dialog = new ContentDialog
                {
                    XamlRoot = XamlRoot, Title = "Turn off borrowing history?",
                    Content = "The library may permanently delete your existing borrowing history.",
                    PrimaryButtonText = "Turn off", CloseButtonText = "Keep history", DefaultButton = ContentDialogButton.Close,
                };
                if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                {
                    // Nothing borrowed-before stays on the device once the library confirms.
                    if (await Save(c => c.SetBorrowingHistoryAsync(false), "Borrowing history turned off.")) _window.Borrowed?.Clear();
                }
                else
                {
                    _filling = true;
                    toggle.IsOn = true;
                    _filling = false;
                }
            };
            stack.Children.Add(new SettingsCard
            {
                Header = "Keep borrowing history", Description = "When on, the library keeps a list of the items you check out.",
                HeaderIcon = new SymbolIcon(Symbol.Clock), Content = toggle,
            });
        }
        if (_window.Borrowed is { } borrowed)
        {
            _refreshBorrowed = new Button { Content = "Refresh Borrowing History" };
            _refreshBorrowed.Click += (_, _) => borrowed.Rebuild(_window.Client);
            _borrowedProgress = new ProgressBar { Width = 200 };
            _borrowedStatus = new TextBlock { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
            _borrowedCard = new SettingsCard
            {
                Header = "Borrowed before", Description = "Marks items you borrowed before. Refreshing reads your whole borrowing history again.",
                HeaderIcon = Icons.Make(ItemListView.BorrowedGlyph),
                Content = new StackPanel
                {
                    Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right,
                    Children = { _refreshBorrowed, _borrowedProgress, _borrowedStatus },
                },
            };
            stack.Children.Add(_borrowedCard);
            UpdateBorrowed();
        }
        _filling = false;
    }

    /// <summary>Refresh Borrowing History, and "Updating · 340 of 1,200" with a small progress bar while syncing.</summary>
    public void UpdateBorrowed()
    {
        if (_window.Borrowed is not { } borrowed || _borrowedCard is null || _refreshBorrowed is null ||
            _borrowedProgress is null || _borrowedStatus is null) return;
        var historyOn = _window.Patron?.BorrowingHistoryEnabled != false;
        _borrowedCard.IsEnabled = historyOn;
        _refreshBorrowed.IsEnabled = historyOn && !borrowed.IsSyncing;
        var syncing = historyOn && borrowed.IsSyncing;
        _borrowedProgress.Visibility = _borrowedStatus.Visibility = syncing ? Visibility.Visible : Visibility.Collapsed;
        if (!syncing) return;
        _borrowedProgress.IsIndeterminate = borrowed.Total == 0;
        _borrowedProgress.Maximum = Math.Max(1, borrowed.Total);
        _borrowedProgress.Value = Math.Min(borrowed.Fetched, borrowed.Total);
        _borrowedStatus.Text = borrowed.Total > 0 ? $"Updating · {borrowed.Fetched:N0} of {borrowed.Total:N0}" : "Updating…";
    }

    /// <summary>The library language closest to Windows' display language (an exact match, else the same base language); null if none.</summary>
    private static string? ClosestToSystem(IReadOnlyList<string> codes)
    {
        var system = System.Globalization.CultureInfo.CurrentUICulture;
        var tag = system.Name.Replace('_', '-');
        var baseLanguage = system.TwoLetterISOLanguageName;
        string Base(string c) => c.Split('-', '_')[0].ToLowerInvariant();
        return codes.FirstOrDefault(c => string.Equals(c.Replace('_', '-'), tag, StringComparison.OrdinalIgnoreCase))
            ?? codes.FirstOrDefault(c => Base(c) == baseLanguage);
    }

    private static Microsoft.UI.Xaml.Input.InputScope Scope(Microsoft.UI.Xaml.Input.InputScopeNameValue value) =>
        new() { Names = { new Microsoft.UI.Xaml.Input.InputScopeName(value) } };

    private async Task<bool> Save(Func<CoreClient, Task> change, string done)
    {
        try
        {
            await change(_window.Client);
            await _window.RefreshPatron();
            _window.ShowMessage(done);
            Refresh();
            return true;
        }
        catch (Exception e) when (e is CoreException or System.IO.IOException or InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            // Event handlers here are async void: an exception that escapes one ends the process.
            _window.ShowMessage(e.Message, error: true);
            Refresh();
            return false;
        }
    }

    /// <summary>
    /// The library card as a scannable barcode, black on white in either theme: Codabar, or Code 128 for
    /// scanners that skip it, a choice kept per library.
    /// </summary>
    private UIElement LibraryCard(string barcode)
    {
        var subdomain = _window.Library.Subdomain;
        var code128 = LibraryStore.Shared.UsesCode128(subdomain);
        var elements = Core.Core.Barcode(barcode, code128);
        var canvas = new Canvas { Height = 64, Width = 360 };
        const double quiet = 10;
        var unit = canvas.Width / (elements.Sum() + 2 * quiet);
        var x = quiet * unit;
        // Elements alternate bar, space, …; the gap after each character is a space, so even indices are bars.
        for (var i = 0; i < elements.Length; i++)
        {
            if (i % 2 == 0)
            {
                var bar = new Rectangle { Width = elements[i] * unit, Height = 64, Fill = new SolidColorBrush(Microsoft.UI.Colors.Black) };
                Canvas.SetLeft(bar, x);
                canvas.Children.Add(bar);
            }
            x += elements[i] * unit;
        }
        var card = new StackPanel
        {
            Spacing = 6, Padding = new Thickness(16), CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Microsoft.UI.Colors.White), HorizontalAlignment = HorizontalAlignment.Left,
            Children =
            {
                canvas,
                new TextBlock
                {
                    Text = barcode, FontFamily = new FontFamily("Consolas"), HorizontalAlignment = HorizontalAlignment.Center,
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.Black),
                },
            },
        };
        if (elements.Length == 0)
            card.Children.Insert(0, new TextBlock
            {
                Text = $"This number can’t be shown as {(code128 ? "Code 128" : "Codabar")}.", Foreground = new SolidColorBrush(Microsoft.UI.Colors.Black),
                TextWrapping = TextWrapping.Wrap, MaxWidth = 360,
            });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, $"Library card barcode {barcode}");
        var type = new ComboBox { Header = "Barcode type", MinWidth = 160, Items = { new ComboBoxItem { Content = "Codabar" }, new ComboBoxItem { Content = "Code 128" } } };
        type.SelectedIndex = code128 ? 1 : 0;
        type.SelectionChanged += (_, _) =>
        {
            if (_filling) return;
            LibraryStore.Shared.SetCode128(subdomain, type.SelectedIndex == 1);
            Refresh();
        };
        return new SettingsCard
        {
            Header = "Library card", Description = "Show this at the library’s self-checkout or desk. Choose Code 128 if a scanner skips Codabar.",
            HeaderIcon = new SymbolIcon(Symbol.ContactInfo),
            Content = new StackPanel { Spacing = 8, Children = { card, type } },
        };
    }
}
