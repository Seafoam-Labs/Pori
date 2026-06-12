using Gtk;
using Pori.Helpers;

namespace Pori.Windows;

public class EditMount : IPoriWindow
{
    private readonly Window _window;

    public EditMount()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/EditMount.ui"), -1);
        _window = (Window)builder.GetObject("AboutWindow")!;
    }

    public Widget CreateWindow() => _window;

    public void Dispose() => _window.Dispose();
}
