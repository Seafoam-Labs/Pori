using Gtk;

namespace Pori.Windows;

public interface IPoriWindow: IDisposable
{
    Widget CreateWindow();
}