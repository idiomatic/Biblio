using Biblio.Core;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Biblio.Views;

/// <summary>Library card, email, password, pickup location, language and borrowing history, as Fluent settings cards.</summary>
public sealed class AccountPage : ScrollViewer
{
    private readonly AccountWindow _window;
    private bool _filling;

    public AccountPage(AccountWindow window)
    {
        _window = window;
        Padding = new Thickness(24, 12, 24, 24);
    }

    public void Refresh()
    {
        var patron = _window.Patron;
        var stack = new StackPanel { Spacing = 4, MaxWidth = 900 };
        Content = stack;
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
        stack.Children.Add(new SettingsCard { Header = "Language", HeaderIcon = new SymbolIcon(Symbol.Globe), Content = language });

        if (patron.BorrowingHistoryEnabled is { } enabled)
        {
            var toggle = new ToggleSwitch { IsOn = enabled };
            toggle.Toggled += async (_, _) =>
            {
                if (_filling) return;
                if (toggle.IsOn) { _ = Save(c => c.SetBorrowingHistoryAsync(true), "Borrowing history turned on."); return; }
                // Turning history off can delete it, so it asks first.
                var dialog = new ContentDialog
                {
                    XamlRoot = XamlRoot, Title = "Turn off borrowing history?",
                    Content = "The library may permanently delete your existing borrowing history.",
                    PrimaryButtonText = "Turn off", CloseButtonText = "Keep history", DefaultButton = ContentDialogButton.Close,
                };
                if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                    _ = Save(c => c.SetBorrowingHistoryAsync(false), "Borrowing history turned off.");
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
        _filling = false;
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
        catch (CoreException e)
        {
            _window.ShowMessage(e.Message, error: true);
            Refresh();
            return false;
        }
    }

    /// <summary>The library card as a scannable Codabar barcode, black on white in either theme.</summary>
    private static UIElement LibraryCard(string barcode)
    {
        var elements = Core.Core.Codabar(barcode);
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
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, $"Library card barcode {barcode}");
        return new SettingsCard
        {
            Header = "Library card", Description = "Show this at the library’s self-checkout or desk.",
            HeaderIcon = new SymbolIcon(Symbol.ContactInfo), Content = card,
        };
    }
}
