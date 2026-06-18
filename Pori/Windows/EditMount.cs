using Gtk;
using Pori.Helpers;
using Pori.Models;
using Pori.Services;

namespace Pori.Windows;

public class EditMount : IPoriWindow
{
    private readonly Box _root;
    private readonly FlowBox _diskFlowBox;
    private readonly IUnPrivOpService _unPrivOpService;
    private readonly IMountCatParser _mountCatParser;

    public EditMount(IUnPrivOpService unPrivOpService, IMountCatParser mountCatParser)
    {
        _unPrivOpService = unPrivOpService;
        _mountCatParser = mountCatParser;

        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/EditMount.ui"), -1);
        _root = (Box)builder.GetObject("DisksBox")!;
        _diskFlowBox = (FlowBox)builder.GetObject("DiskFlowBox")!;
        var refreshButton = (Button)builder.GetObject("RefreshButton")!;

        refreshButton.OnClicked += (_, _) => _ = LoadDataAsync();

        _diskFlowBox.SetOrientation(Orientation.Vertical);

        _ = LoadDataAsync();
    }

    public void Refresh() => _ = LoadDataAsync();

    private async Task LoadDataAsync()
    {
        var listResult = await _unPrivOpService.GetActiveMountUnitsAsync();
        if (!listResult.Success)
            return;

        var unitNames = _mountCatParser.ParseMountUnitNames(listResult.Output)
            .Where(u => File.Exists(Path.Combine("/etc/systemd/system", u)))
            .ToList();

        var mounts = new List<MountCatInfo>();
        foreach (var unitName in unitNames)
        {
            var showResult = await _unPrivOpService.GetMountUnitShowAsync(unitName);
            var showOutput = showResult.Success ? showResult.Output : string.Empty;
            mounts.Add(_mountCatParser.ParseMountShow(unitName, showOutput));
        }

        GLib.Functions.IdleAdd(0, () =>
        {
            PopulateDiskList(mounts);
            return false;
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
