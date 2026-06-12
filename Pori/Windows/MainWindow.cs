using Gtk;
using Pori.Helpers;
using Pori.Models;
using Pori.Services;
using Pori.Windows.Dialog;

namespace Pori.Windows;

public class MainWindow
{
    private readonly ApplicationWindow _window;
    private readonly Overlay _mainOverlay;
    private readonly PasswordDialog _passwordDialog;

    public MainWindow(ICredentialManager credentialManager, PasswordDialog passwordDialog, IServiceProvider serviceProvider)
    {
        _passwordDialog = passwordDialog;

        credentialManager.CredentialRequested += OnCredentialRequested;

        var mainBuilder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/MainWindow.ui"), -1);
        _window = (ApplicationWindow)mainBuilder.GetObject("MainWindow")!;
        _mainOverlay = (Overlay)mainBuilder.GetObject("MainOverlay")!;

        var stack = (Stack)mainBuilder.GetObject("MainStack")!;
        var navDisks = (ToggleButton)mainBuilder.GetObject("NavDisksButton")!;
        var navSettings = (ToggleButton)mainBuilder.GetObject("NavSettingsButton")!;
        var navAbout = (ToggleButton)mainBuilder.GetObject("NavAboutButton")!;

        navDisks.OnToggled += (s, _) =>
        {
            if (!s.Active) return;
            stack.VisibleChildName = "disks_page";
            navSettings.Active = false;
            navAbout.Active = false;
        };

        navSettings.OnToggled += (s, _) =>
        {
            if (!s.Active) return;
            stack.VisibleChildName = "settings_page";
            navDisks.Active = false;
            navAbout.Active = false;
        };

        navAbout.OnToggled += (s, _) =>
        {
            if (!s.Active) return;
            stack.VisibleChildName = "about_page";
            navDisks.Active = false;
            navSettings.Active = false;
        };

        var disksBox = (Box)mainBuilder.GetObject("DisksPageBox")!;
        var disksPage = Microsoft.Extensions.DependencyInjection.ServiceProviderServiceExtensions.GetRequiredService<DisksPage>(serviceProvider);
        disksPage.SetOverlay(_mainOverlay);
        disksBox.Append(disksPage.GetContent());

        var settingsBox = (Box)mainBuilder.GetObject("SettingsPageBox")!;
        var settingsBuilder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/EditMount.ui"), -1);
        var settingsContent = (Box)settingsBuilder.GetObject("SettingsBox")!;
        settingsBox.Append(settingsContent);

        var aboutBox = (Box)mainBuilder.GetObject("AboutPageBox")!;
        var aboutBuilder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Unmount.ui"), -1);
        var aboutContent = (Box)aboutBuilder.GetObject("AboutBox")!;
        aboutBox.Append(aboutContent);
        
        var versionLabel = (Label)mainBuilder.GetObject("VersionLabel")!;
        var version = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "0.0.1";
        versionLabel.SetText($"v{version}");
        
        _window.SetIconName("pori");
    }

    public void Show(Application application)
    {
        _window.SetIconName("pori");
        _window.Application = application;
        _window.Show();
    }

    private void OnCredentialRequested(object? sender, CredentialRequestEventArgs e)
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            _passwordDialog.ShowPasswordDialog(_mainOverlay, e.Reason);
            return false;
        });
    }
}
