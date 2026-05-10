using Gtk;

namespace Sponge.Windows;

public interface ISpongeWindow: IDisposable
{
    Widget CreateWindow();
}