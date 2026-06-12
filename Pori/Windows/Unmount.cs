using Gtk;
using Pori.Helpers;
using Pori.Services;

namespace Pori.Windows;

public class Unmount : IPoriWindow
{
    private readonly Box _root;
    private List<string> _mounts = [];
    private readonly FlowBox _diskFlowBox;
    private readonly Button _mountButton;
    private readonly IPrivOpService _privOpService;
    private readonly IUnPrivOpService _unPrivOpService;
    private readonly IMountFileParser _mountFileParser;

    private string? _selectedMount;
    
    public Unmount(IPrivOpService privOpService, IUnPrivOpService unPrivOpService, IMountFileParser mountFileParser)
    {
        _privOpService = privOpService;
        _unPrivOpService = unPrivOpService;
        _mountFileParser = mountFileParser;

        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Unmount.ui"), -1);
        _root = (Box)builder.GetObject("DisksBox")!;
        _diskFlowBox = (FlowBox)builder.GetObject("DiskFlowBox")!;
        _mountButton = (Button)builder.GetObject("MountButton")!;
        var refreshButton = (Button)builder.GetObject("RefreshButton")!;

        _diskFlowBox.SetOrientation(Orientation.Vertical);

        _diskFlowBox.OnSelectedChildrenChanged += (_, _) =>
        {
            _selectedMount = null;
            _diskFlowBox.SelectedForeach((_, child) =>
            {
                var index = child.GetIndex();
                if (index >= 0 && index < _mounts.Count)
                {
                    _selectedMount = _mounts[index];
                }
            });
            _mountButton.SetSensitive(_selectedMount != null);
        };

        _mountButton.OnClicked += OnUnmountClicked;
        refreshButton.OnClicked += (_, _) => _ = LoadDataAsync();

        _ = LoadDataAsync();
    }

    private void OnUnmountClicked(Button sender, EventArgs args)
    {
        if (_selectedMount == null)
            return;

        _ = Task.Run(async () =>
        {
            var unitName = Path.GetFileName(_selectedMount);
            var result = await _privOpService.DeleteMountUnitAsync(unitName);
            Console.WriteLine(result.Success
                ? $"Unmounted: {unitName}"
                : $"Failed to unmount: {result.Error}");

            if (result.Success)
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _ = LoadDataAsync();
                    return false;
                });
            }
        });
    }

    private async Task LoadDataAsync()
    {
        _mounts = [];
        const string mountFiles = "/etc/systemd/system";

        var potFiles = Directory.EnumerateFiles(mountFiles);
        foreach (var file in potFiles)
        {
            if (file.EndsWith(".mount"))
                _mounts.Add(file);
        }

        var statusResults = new Dictionary<string, string>();
        foreach (var mount in _mounts)
        {
            var unitName = Path.GetFileName(mount);
            var result = await _unPrivOpService.GetMountUnitInfoAsync(unitName);
            statusResults[mount] = result.Success ? result.Output : string.Empty;
        }

        GLib.Functions.IdleAdd(0, () =>
        {
            PopulateDiskList(statusResults);
            return false;
        });
    }
    
    private void PopulateDiskList(Dictionary<string, string> statusResults)
    {
        while (_diskFlowBox.GetFirstChild() is { } child)
            _diskFlowBox.Remove(child);

        foreach (var mount in _mounts)
        {
            var status = statusResults.GetValueOrDefault(mount, string.Empty);
            _diskFlowBox.Append(CreateDiskCard(mount, status));
        }

        _diskFlowBox.SetFilterFunc(child => true);
    }
    
    private Widget CreateDiskCard(string mount, string statusOutput)
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

        var unitName = Path.GetFileName(mount);
        var info = _mountFileParser.ParseMountUnitStatus(statusOutput);

        AddCardField(contentBox, "Unit", unitName, true);
        if (!string.IsNullOrWhiteSpace(info.Description))
            AddCardField(contentBox, "Description", info.Description, false);
        if (!string.IsNullOrWhiteSpace(info.Where))
            AddCardField(contentBox, "Mount Point", info.Where, false);
        if (!string.IsNullOrWhiteSpace(info.What))
            AddCardField(contentBox, "Device", info.What, false);
        if (!string.IsNullOrWhiteSpace(info.Active))
            AddCardField(contentBox, "Status", info.Active, false);

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
    
    public void Refresh() => _ = LoadDataAsync();

    public Widget CreateWindow() => _root;

    public void Dispose() => _root.Dispose();
}
