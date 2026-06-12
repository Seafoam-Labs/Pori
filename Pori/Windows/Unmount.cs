using Gtk;
using Pori.Helpers;

namespace Pori.Windows;

public class Unmount : IPoriWindow
{
    private readonly Window _window;

    public Unmount()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Unmount.ui"), -1);
        _window = (Window)builder.GetObject("SettingsWindow")!;
    }

    public Widget CreateWindow() => _window;

    public void Dispose() => _window.Dispose();
}
