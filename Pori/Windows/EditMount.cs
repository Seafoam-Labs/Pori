using Gtk;
using Pori.Helpers;
using Pori.Models;
using Pori.Services;
using Pori.Windows.Dialog;

namespace Pori.Windows;

public class EditMount : IPoriWindow
{
    private readonly Box _root;
    private readonly FlowBox _diskFlowBox;
    private readonly IUnPrivOpService _unPrivOpService;
    private readonly IPrivOpService _privOpService;
    private readonly IMountCatParser _mountCatParser;

    private List<MountCatInfo> MountInfo { get; set; } = [];
    private MountCatInfo? _selectedModel;
    private Overlay? _mainOverlay;

    public EditMount(IUnPrivOpService unPrivOpService, IPrivOpService privOpService, IMountCatParser mountCatParser)
    {
        _unPrivOpService = unPrivOpService;
        _mountCatParser = mountCatParser;
        _privOpService = privOpService;

        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/EditMount.ui"), -1);
        _root = (Box)builder.GetObject("DisksBox")!;
        _diskFlowBox = (FlowBox)builder.GetObject("DiskFlowBox")!;
        var refreshButton = (Button)builder.GetObject("RefreshButton")!;
        var editButton = (Button)builder.GetObject("EditButton")!;

        refreshButton.OnClicked += (_, _) => _ = LoadDataAsync();
        editButton.OnClicked += (_, _) => _ = EditMountAsync();

        _diskFlowBox.SetOrientation(Orientation.Vertical);

        _diskFlowBox.OnSelectedChildrenChanged += (_, _) =>
        {
            _selectedModel = null;
            _diskFlowBox.SelectedForeach((_, child) =>
            {
                var index = child.GetIndex();
                if (index >= 0 && index < MountInfo.Count)
                {
                    _selectedModel = MountInfo[index];
                }
            });
            editButton.SetSensitive(_selectedModel != null);
        };
    }

    public void Refresh() => _ = LoadDataAsync();

    public void SetOverlay(Overlay overlay) => _mainOverlay = overlay;

    private async Task LoadDataAsync()
    {
        MountInfo.Clear();

        var listResult = await _unPrivOpService.GetActiveMountUnitsAsync();
        if (!listResult.Success)
            return;

        var unitNames = _mountCatParser.ParseMountUnitNames(listResult.Output)
            .Where(u => File.Exists(Path.Combine("/etc/systemd/system", u)))
            .ToList();

        foreach (var unitName in unitNames)
        {
            var catResult = await _privOpService.GetMountUnitCatAsync(unitName);
            var catOutput = catResult.Success ? catResult.Output : string.Empty;
            MountInfo.Add(_mountCatParser.ParseMountCat(unitName, catOutput));
        }

        GLib.Functions.IdleAdd(0, () =>
        {
            PopulateDiskList(MountInfo);
            return false;
        });
    }

    private async Task EditMountAsync()
    {
        Console.WriteLine($"Edit Mount {_selectedModel?.Where}");
        if (_selectedModel == null)
            return;
        
        _ = ShowMountDialog(_selectedModel);
    }

    private async Task ShowMountDialog(MountCatInfo model)
    {
        var result = await MountOptionsDialog.EditMountOptionsAsync(_mainOverlay!, model);
        if (result == null)
            return;

        _ = Task.Run(async () =>
        {
            var createResult =
                await _privOpService.EditMountUnitFileAsync(_selectedModel.UnitName, result.Description, result.MountPoint, _selectedModel.Type, result.Options);
            Console.WriteLine(createResult.Success
                ? $"Mount edited: {createResult.Output}"
                : $"Failed to edit mount unit: {createResult.Error}");

            if (createResult.Success)
            {
                var unitName = result.MountPoint.Trim('/').Replace('/', '-') + ".mount";
                await _privOpService.MountDrives(unitName);

                GLib.Functions.IdleAdd(0, () =>
                {
                    _ = LoadDataAsync();
                    return false;
                });
            }
        });
    }

    private void PopulateDiskList(List<MountCatInfo> mounts)
    {
        while (_diskFlowBox.GetFirstChild() is { } child)
            _diskFlowBox.Remove(child);

        foreach (var mount in mounts)
            _diskFlowBox.Append(CreateDiskCard(mount));
    }

    private static Widget CreateDiskCard(MountCatInfo model)
    {
        var frame = Frame.New(null);
        frame.AddCssClass("card");
        frame.SetSizeRequest(260, -1);

        var contentBox = Box.New(Orientation.Vertical, 4);
        contentBox.SetMarginTop(10);
        contentBox.SetMarginBottom(10);
        contentBox.SetMarginStart(10);
        contentBox.SetMarginEnd(10);

        var titleLabel = Label.New(model.UnitName);
        titleLabel.SetXalign(0);
        titleLabel.AddCssClass("heading");
        titleLabel.SetEllipsize(Pango.EllipsizeMode.End);
        contentBox.Append(titleLabel);

        if (!string.IsNullOrWhiteSpace(model.Description))
            AddCardField(contentBox, "Description", model.Description, false);
        if (!string.IsNullOrWhiteSpace(model.Where))
            AddCardField(contentBox, "Where", model.Where, false);
        if (!string.IsNullOrWhiteSpace(model.What))
            AddCardField(contentBox, "What", model.What, false);
        if (!string.IsNullOrWhiteSpace(model.Type))
            AddCardField(contentBox, "Type", model.Type, false);
        if (!string.IsNullOrWhiteSpace(model.Options))
            AddCardField(contentBox, "Options", model.Options, false);

        frame.SetChild(contentBox);
        return frame;
    }

    private static void AddCardField(Box box, string fieldName, string value, bool bold)
    {
        var hbox = Box.New(Orientation.Horizontal, 4);

        var nameLabel = Label.New(fieldName + ":");
        nameLabel.SetXalign(0);
        nameLabel.AddCssClass("dim-label");
        nameLabel.SetSizeRequest(80, -1);

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