using Gtk;
using Pori.Helpers;

namespace Pori.Windows;

public class EditMount : IPoriWindow
{
    private readonly Box _root;
    private List<string> _mounts = [];
    private readonly FlowBox _diskFlowBox;
    private readonly Button _mountButton;
    
    public EditMount()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/EditMount.ui"), -1);
        _root = (Box)builder.GetObject("DisksBox")!;
        _diskFlowBox = (FlowBox)builder.GetObject("DiskFlowBox")!;
        _mountButton = (Button)builder.GetObject("MountButton")!;
        
        LoadData();
    }

    public void Refresh() => LoadData();

    private void LoadData()
    {
        _mounts = [];
        const string mountFiles = "/etc/systemd/system";

        var potFiles = Directory.EnumerateFiles(mountFiles);
        foreach (var file in potFiles)
        {
            if (file.EndsWith(".mount"))
            {
                _mounts.Add(file);
            }
        }
        PopulateDiskList();
    }
    
    private void PopulateDiskList()
    {
        while (_diskFlowBox.GetFirstChild() is { } child)
            _diskFlowBox.Remove(child);

        foreach (var card in _mounts.Select(CreateDiskCard))
        {
            _diskFlowBox.Append(card);
        }

        _diskFlowBox.SetFilterFunc(child =>
        {
            return true;
        });
    }
    
    private static Widget CreateDiskCard(string mount)
    {
        var frame = Frame.New(null);
        frame.AddCssClass("card");
        frame.SetSizeRequest(220, -1);

        var mainBox = Box.New(Orientation.Vertical, 0);

        var contentBox = Box.New(Orientation.Vertical, 4);
        contentBox.SetMarginTop(10);
        contentBox.SetMarginBottom(10);
        contentBox.SetMarginStart(10);
        contentBox.SetMarginEnd(10);

        AddCardField(contentBox, "Mount", mount, true);

        mainBox.Append(contentBox);
        
        frame.SetChild(mainBox);
        return frame;
    }
    
    private static void AddCardField(Box box, string fieldName, string value, bool bold)
    {
        var hbox = Box.New(Orientation.Horizontal, 4);

        var nameLabel = Label.New(fieldName + ":");
        nameLabel.SetXalign(0);
        nameLabel.AddCssClass("dim-label");
        nameLabel.SetSizeRequest(70, -1);

        var valueLabel = Label.New(value);
        valueLabel.SetXalign(0);
        valueLabel.SetHexpand(true);
        valueLabel.SetEllipsize(Pango.EllipsizeMode.End);
        if (bold)
            valueLabel.AddCssClass("heading");

        hbox.Append(nameLabel);
        hbox.Append(valueLabel);
        box.Append(hbox);
    }

    public Widget CreateWindow() => _root;

    public void Dispose() => _root.Dispose();
}
