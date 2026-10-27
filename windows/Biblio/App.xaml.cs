using Biblio.Views;
using Microsoft.UI.Xaml;

namespace Biblio;

/// <summary>Biblio for Windows: WinUI 3 with Fluent design, on the shared Zig core.</summary>
public partial class App : Application
{
    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args) => LauncherWindow.Open();
}
