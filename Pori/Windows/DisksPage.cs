using Gtk;
using Pori.Helpers;
using Pori.Models;
using Pori.Services;
using Pori.Windows.Dialog;

namespace Pori.Windows;

public class DisksPage : IPoriWindow
{
    private readonly Box _content;
    private readonly FlowBox _diskFlowBox;
    private readonly Button _mountButton;
    private readonly IUnPrivOpService _unPrivOpService;
    private readonly IPrivOpService _privOpService;
    private readonly IFStabParser _fStabParser;

    private Overlay? _mainOverlay;
    private FStabModel? _selectedModel;

    private List<FStabModel> FStabModels { get; set; } = [];

    
    public Widget CreateWindow() => _content;
    
    public DisksPage(IUnPrivOpService unPrivOpService, IPrivOpService privOpService, IFStabParser fStabParser) 
    {
        _unPrivOpService = unPrivOpService;
        _privOpService = privOpService;
        _fStabParser = fStabParser;

        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/DisksPage.ui"), -1);
        _content = (Box)builder.GetObject("DisksBox")!;
        _diskFlowBox = (FlowBox)builder.GetObject("DiskFlowBox")!;
        _mountButton = (Button)builder.GetObject("MountButton")!;
        var refreshButton = (Button)builder.GetObject("RefreshButton")!;

        refreshButton.OnClicked += (_, _) => _ = LoadFStabDataAsync();

        _diskFlowBox.SetOrientation(Orientation.Vertical);
        
        _diskFlowBox.OnSelectedChildrenChanged += (_, _) =>
        {
            _selectedModel = null;
            _diskFlowBox.SelectedForeach((_, child) =>
            {
                var index = child.GetIndex();
                var selectableModels = FStabModels.Where(m =>
                    !string.IsNullOrWhiteSpace(m.FsType) &&
                    !string.IsNullOrWhiteSpace(m.Uuid) &&
                    !m.MountPoints.Equals("[SWAP]", StringComparison.OrdinalIgnoreCase)).ToList();

                if (index >= 0 && index < selectableModels.Count)
                {
                    _selectedModel = selectableModels[index];
                }
            });
            _mountButton.SetSensitive(_selectedModel != null && string.IsNullOrWhiteSpace(_selectedModel.MountPoints));
        };

        _mountButton.OnClicked += OnMountClicked;

        _ = LoadFStabDataAsync();
    }

    public void Refresh() => _ = LoadFStabDataAsync();

    public Box GetContent() => _content;

    public void SetOverlay(Overlay overlay) => _mainOverlay = overlay;

    private void OnMountClicked(Button sender, EventArgs args)
    {
        if (_selectedModel == null)
            return;

        if (_selectedModel.FsType.Equals("ntfs", StringComparison.OrdinalIgnoreCase))
        {
            _ = ShowNtfsWarningThenMount(_selectedModel);
        }
        else
        {
            _ = ShowMountDialog(_selectedModel);
        }
    }

    private async Task ShowNtfsWarningThenMount(FStabModel model)
    {
        var proceed = await NtfsWarning.ShowNtfsWarningAsync(_mainOverlay);
        if (proceed)
        {
            await ShowMountDialog(model);
        }
    }

    private async Task ShowMountDialog(FStabModel model)
    {
        var result = await MountOptionsDialog.ShowMountOptionsAsync(_mainOverlay, model);
        if (result == null)
            return;

        _ = Task.Run(async () =>
        {
            var createResult =
                await _privOpService.CreateMountUnitFileAsync(result.Description, model.Uuid, result.MountPoint, model.FsType,
                    result.Options);
            Console.WriteLine(createResult.Success
                ? $"Mount unit created: {createResult.Output}"
                : $"Failed to create mount unit: {createResult.Error}");

            if (createResult.Success)
            {
                var unitName = result.MountPoint.Trim('/').Replace('/', '-') + ".mount";
                await _privOpService.MountDrives(unitName);

                GLib.Functions.IdleAdd(0, () =>
                {
                    _ = LoadFStabDataAsync();
                    return false;
                });
            }
        });
    }

    private async Task LoadFStabDataAsync()
    {
        var result = await _unPrivOpService.GetFstabDashLAsync();
        if (result.Success)
        {
            FStabModels = _fStabParser.Parse(result.Output);
            PopulateDiskList();
        }
    }

    private void PopulateDiskList()
    {
        while (_diskFlowBox.GetFirstChild() is { } child)
            _diskFlowBox.Remove(child);

        foreach (var model in FStabModels.Where(m =>
                     !string.IsNullOrWhiteSpace(m.FsType) &&
                     !string.IsNullOrWhiteSpace(m.Uuid) &&
                     !m.MountPoints.Equals("[SWAP]", StringComparison.OrdinalIgnoreCase)))
        {
            var hasMountPoint = !string.IsNullOrWhiteSpace(model.MountPoints);
            var card = CreateDiskCard(model, hasMountPoint);
            _diskFlowBox.Append(card);
        }

        _diskFlowBox.SetFilterFunc(child =>
        {
            return true;
        });
    }

    private static Widget CreateDiskCard(FStabModel model, bool hasMountPoint)
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

        AddCardField(contentBox, "Name", model.Name, true);
        AddCardField(contentBox, "Type", model.FsType, false);
        if (!string.IsNullOrWhiteSpace(model.Fsver))
            AddCardField(contentBox, "Version", model.Fsver, false);
        if (!string.IsNullOrWhiteSpace(model.Label))
            AddCardField(contentBox, "Label", model.Label, false);
        AddCardField(contentBox, "UUID", model.Uuid, false);
        if (!string.IsNullOrWhiteSpace(model.FSavail))
            AddCardField(contentBox, "Available", model.FSavail, false);
        if (!string.IsNullOrWhiteSpace(model.FSused))
        {
            AddCardField(contentBox, "Use%", model.FSused, false);
            AddUsageBar(contentBox, model.FSused);
        }
        if (hasMountPoint)
            AddCardField(contentBox, "Mount", model.MountPoints, false);

        mainBox.Append(contentBox);
        
        if (hasMountPoint)
        {
            frame.SetTooltipText("Already mounted at " + model.MountPoints);
            frame.SetSensitive(false);
        }

        frame.SetChild(mainBox);
        return frame;
    }

    private static void AddUsageBar(Box box, string usedPercent)
    {
        if (!int.TryParse(usedPercent.TrimEnd('%'), out var pct))
            return;

        var levelBar = LevelBar.New();
        levelBar.SetMinValue(0);
        levelBar.SetMaxValue(100);
        levelBar.SetValue(pct);
        levelBar.SetMarginTop(2);
        levelBar.SetMarginBottom(4);
        levelBar.AddOffsetValue("low", 33);
        levelBar.AddOffsetValue("high", 66);
        levelBar.AddOffsetValue("full", 100);
        box.Append(levelBar);
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

    public void Dispose() => _content.Dispose();

}
