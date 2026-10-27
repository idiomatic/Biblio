using Biblio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Biblio.Views;

/// <summary>Chooses a library and a user (or guest), then opens that account's window.</summary>
public sealed class LauncherWindow : Window
{
    private readonly Frame _frame = new();
    private readonly LibraryStore _store = LibraryStore.Shared;

    public static void Open() => new LauncherWindow().Activate();

    private LauncherWindow()
    {
        Title = "Biblio";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(520, 640));
        Content = new Grid
        {
            RowDefinitions = { new RowDefinition { Height = new GridLength(32) }, new RowDefinition() },
            Children = { TitleBarText("Biblio"), WithRow(_frame, 1) },
        };
        ShowLibraries();
    }

    internal static TextBlock TitleBarText(string text) => new()
    {
        Text = text, Margin = new Thickness(16, 8, 0, 0), Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
    };

    internal static FrameworkElement WithRow(FrameworkElement e, int row)
    {
        Grid.SetRow(e, row);
        return e;
    }

    private static TextBlock Heading(string text) => new()
    {
        Text = text, Style = (Style)Application.Current.Resources["TitleTextBlockStyle"], Margin = new Thickness(0, 0, 0, 12),
    };

    private void Show(UIElement page) => _frame.Content = new ScrollViewer { Content = page, Padding = new Thickness(24, 12, 24, 24) };

    // MARK: Libraries

    private void ShowLibraries()
    {
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(Heading("Libraries"));
        if (_store.Libraries.Count == 0)
            stack.Children.Add(new TextBlock
            {
                Text = "Add your library to search its catalog, place holds and see what you have checked out.",
                TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
        foreach (var lib in _store.Libraries)
        {
            var count = lib.Users?.Count ?? 0;
            var card = new CommunityToolkit.WinUI.Controls.SettingsCard
            {
                Header = lib.Name,
                Description = count switch { 0 => "No users", 1 => "1 user", _ => $"{count} users" },
                HeaderIcon = new SymbolIcon(Symbol.Library),
                IsClickEnabled = true,
            };
            card.Click += (_, _) => ShowLibrary(lib.Subdomain);
            stack.Children.Add(card);
        }
        var add = new Button { Content = "Add Library…", Style = (Style)Application.Current.Resources["AccentButtonStyle"], Margin = new Thickness(0, 12, 0, 0) };
        add.Click += async (_, _) => { if (await AddLibraryDialog.Show(Content.XamlRoot)) ShowLibraries(); };
        stack.Children.Add(add);
        Show(stack);
    }

    // MARK: One library

    private void ShowLibrary(string subdomain)
    {
        var lib = _store.Library(subdomain);
        if (lib is null) { ShowLibraries(); return; }
        var stack = new StackPanel { Spacing = 4 };
        var back = new Button { Content = new SymbolIcon(Symbol.Back), Margin = new Thickness(0, 0, 0, 8) };
        ToolTipService.SetToolTip(back, "Back");
        back.Click += (_, _) => ShowLibraries();
        stack.Children.Add(back);
        stack.Children.Add(Heading(lib.DisplayName));

        foreach (var user in lib.Users ?? [])
        {
            var remove = new Button { Content = new SymbolIcon(Symbol.Delete) };
            ToolTipService.SetToolTip(remove, $"Remove {user}");
            remove.Click += (_, _) => { _store.RemoveUser(subdomain, user); ShowLibrary(subdomain); };
            var card = new CommunityToolkit.WinUI.Controls.SettingsCard
            {
                Header = user, HeaderIcon = new SymbolIcon(Symbol.Contact), IsClickEnabled = true, Content = remove,
            };
            card.Click += (_, _) => OpenAccount(subdomain, user);
            stack.Children.Add(card);
        }
        var addUser = new CommunityToolkit.WinUI.Controls.SettingsCard
        {
            Header = "Add User…", HeaderIcon = new SymbolIcon(Symbol.AddFriend), IsClickEnabled = true,
        };
        addUser.Click += async (_, _) =>
        {
            if (await AddUserDialog.Show(Content.XamlRoot, lib) is { } added) OpenAccount(subdomain, added);
        };
        stack.Children.Add(addUser);

        var guest = new CommunityToolkit.WinUI.Controls.SettingsCard
        {
            Header = "Browse as Guest",
            Description = "Guests can search and browse the catalog but can’t place holds or see an account.",
            HeaderIcon = new SymbolIcon(Symbol.Globe), IsClickEnabled = true, Margin = new Thickness(0, 16, 0, 0),
        };
        guest.Click += (_, _) => OpenAccount(subdomain, "");
        stack.Children.Add(guest);

        var removeLibrary = new Button { Content = "Remove Library", Margin = new Thickness(0, 24, 0, 0) };
        removeLibrary.Click += async (_, _) =>
        {
            // Asks only when users and their passwords would be removed too.
            if ((lib.Users?.Count ?? 0) > 0)
            {
                var dialog = new ContentDialog
                {
                    XamlRoot = Content.XamlRoot,
                    Title = $"Remove {lib.Name}?",
                    Content = "Its saved users and passwords will also be removed from this device.",
                    PrimaryButtonText = "Remove", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
                };
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            }
            _store.Remove(subdomain);
            ShowLibraries();
        };
        stack.Children.Add(removeLibrary);
        Show(stack);
    }

    private void OpenAccount(string subdomain, string username)
    {
        if (_store.Library(subdomain) is not { } lib) return;
        AccountWindow.Open(lib, username);
        Close();
    }
}
