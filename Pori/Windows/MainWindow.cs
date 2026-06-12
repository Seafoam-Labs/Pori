using Gtk;
using Microsoft.Extensions.DependencyInjection;
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

        var disksBox = (Box)mainBuilder.GetObject("DisksPageBox")!;
        var disksPage = serviceProvider.GetRequiredService<DisksPage>();
        disksPage.SetOverlay(_mainOverlay);
        disksBox.Append(disksPage.CreateWindow());

        var editMountBox = (Box)mainBuilder.GetObject("EditMountPageBox")!;
        var editMountPage = serviceProvider.GetRequiredService<EditMount>();
        editMountBox.Append(editMountPage.CreateWindow());

        var unmountBox = (Box)mainBuilder.GetObject("UnMountPageBox")!;
        var unmountPage = serviceProvider.GetRequiredService<Unmount>();
        unmountBox.Append(unmountPage.CreateWindow());

        navDisks.OnToggled += (s, _) =>
        {
            if (!s.Active) return;
            stack.VisibleChildName = "disks_page";
            navSettings.Active = false;
            navAbout.Active = false;
            disksPage.Refresh();
        };

        navSettings.OnToggled += (s, _) =>
        {
            if (!s.Active) return;
            stack.VisibleChildName = "settings_page";
            navDisks.Active = false;
            navAbout.Active = false;
            editMountPage.Refresh();
        };

        navAbout.OnToggled += (s, _) =>
        {
            if (!s.Active) return;
            stack.VisibleChildName = "about_page";
            navDisks.Active = false;
            navSettings.Active = false;
            unmountPage.Refresh();
        };
        
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
