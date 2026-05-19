using Gtk;
using Pori.Helpers;
using Pori.Models;
using Pori.Services;
using Pori.Windows.Dialog;

namespace Pori.Windows;

public class MainWindow
{
    private readonly ApplicationWindow _window;
    private readonly Overlay _mainOverlay;
    private readonly FlowBox _diskFlowBox;
    private readonly Button _mountButton;
    private readonly IUnPrivOpService _unPrivOpService;
    private readonly IPrivOpService _privOpService;
    private readonly IFStabParser _fStabParser;
    private readonly ICredentialManager _credentialManager;
    private readonly PasswordDialog _passwordDialog;

    public List<FStabModel> FStabModels { get; private set; } = [];

    public MainWindow(IUnPrivOpService unPrivOpService, IPrivOpService privOpService, IFStabParser fStabParser, ICredentialManager credentialManager, PasswordDialog passwordDialog)
    {
        _unPrivOpService = unPrivOpService;
        _privOpService = privOpService;
        _fStabParser = fStabParser;
        _credentialManager = credentialManager;
        _passwordDialog = passwordDialog;
       

        _credentialManager.CredentialRequested += OnCredentialRequested;

        var mainBuilder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/MainWindow.ui"), -1);
        _window = (ApplicationWindow)mainBuilder.GetObject("MainWindow")!;
        _mainOverlay = (Overlay)mainBuilder.GetObject("MainOverlay")!;
        _diskFlowBox = (FlowBox)mainBuilder.GetObject("DiskFlowBox")!;
        _mountButton = (Button)mainBuilder.GetObject("MountButton")!;
        
        _window.SetIconName("pori");

        var refreshButton = (Button)mainBuilder.GetObject("RefreshButton")!;
        refreshButton.OnClicked += (_, _) => _ = LoadFStabDataAsync();

        _diskFlowBox.OnSelectedChildrenChanged += (_, _) =>
        {
            var hasSelection = false;
            _diskFlowBox.SelectedForeach((_, _) => hasSelection = true);
            _mountButton.SetSensitive(hasSelection);
        };

        _mountButton.OnClicked += OnMountClicked;
    }

    public void Show(Application application)
    {
        _window.SetIconName("pori");
        _window.Application = application;
        _window.Show();

        _ = LoadFStabDataAsync();
    }

    public ApplicationWindow GetWindow() => _window;

    private void OnMountClicked(Button sender, EventArgs args)
    {
        FlowBoxChild? selectedChild = null;
        _diskFlowBox.SelectedForeach((_, child) => selectedChild ??= child);
        if (selectedChild == null)
            return;

        var index = selectedChild.GetIndex();
        var selectableModels = FStabModels.Where(m =>
            !string.IsNullOrWhiteSpace(m.FsType) &&
            !string.IsNullOrWhiteSpace(m.Uuid) &&
            !m.MountPoints.Equals("[SWAP]", StringComparison.OrdinalIgnoreCase) &&
            string.IsNullOrWhiteSpace(m.MountPoints)).ToList();

        if (index >= 0 && index < selectableModels.Count)
        {
            var model = selectableModels[index];
            if (model.FsType.Equals("ntfs", StringComparison.OrdinalIgnoreCase))
            {
                _ = ShowNtfsWarningThenMount(model);
            }
            else
            {
                _ = ShowMountDialog(model);
            }
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

    private void OnCredentialRequested(object? sender, CredentialRequestEventArgs e)
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            _passwordDialog.ShowPasswordDialog(_mainOverlay, e.Reason);
            return false;
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
            // All children are visible
            return true;
        });
    }

    private static Widget CreateDiskCard(FStabModel model, bool hasMountPoint)
    {
        var frame = Frame.New(null);
        frame.AddCssClass("card");
        frame.SetSizeRequest(220, -1);

        var box = Box.New(Orientation.Vertical, 4);
        box.SetMarginTop(10);
        box.SetMarginBottom(10);
        box.SetMarginStart(10);
        box.SetMarginEnd(10);

        AddCardField(box, "Name", model.Name, true);
        AddCardField(box, "Type", model.FsType, false);
        if (!string.IsNullOrWhiteSpace(model.Fsver))
            AddCardField(box, "Version", model.Fsver, false);
        if (!string.IsNullOrWhiteSpace(model.Label))
            AddCardField(box, "Label", model.Label, false);
        AddCardField(box, "UUID", model.Uuid, false);
        if (!string.IsNullOrWhiteSpace(model.FSavail))
            AddCardField(box, "Available", model.FSavail, false);
        if (!string.IsNullOrWhiteSpace(model.FSused))
            AddCardField(box, "Use%", model.FSused, false);
        if (hasMountPoint)
            AddCardField(box, "Mount", model.MountPoints, false);

        if (hasMountPoint)
        {
            frame.SetSensitive(false);
            frame.SetTooltipText("Already mounted at " + model.MountPoints);
        }

        frame.SetChild(box);
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
}