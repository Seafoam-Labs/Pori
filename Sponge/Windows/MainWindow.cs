using Gtk;
using Sponge.Helpers;
using Sponge.Models;
using Sponge.Services;
using Sponge.Windows.Dialog;

namespace Sponge.Windows;

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
    private readonly NtfsWarning _ntfsWarning;
    private Widget? _overlayWidget;

    public List<FStabModel> FStabModels { get; private set; } = [];

    public MainWindow(IUnPrivOpService unPrivOpService, IPrivOpService privOpService, IFStabParser fStabParser, ICredentialManager credentialManager, PasswordDialog passwordDialog, NtfsWarning ntfsWarning)
    {
        _unPrivOpService = unPrivOpService;
        _privOpService = privOpService;
        _fStabParser = fStabParser;
        _credentialManager = credentialManager;
        _passwordDialog = passwordDialog;
        _ntfsWarning = ntfsWarning;

        _credentialManager.CredentialRequested += OnCredentialRequested;

        var mainBuilder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/MainWindow.ui"), -1);
        _window = (ApplicationWindow)mainBuilder.GetObject("MainWindow")!;
        _mainOverlay = (Overlay)mainBuilder.GetObject("MainOverlay")!;
        _diskFlowBox = (FlowBox)mainBuilder.GetObject("DiskFlowBox")!;
        _mountButton = (Button)mainBuilder.GetObject("MountButton")!;

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
        _window.SetIconName("sponge");
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
                ShowMountOverlay(model);
            }
        }
    }

    private async Task ShowNtfsWarningThenMount(FStabModel model)
    {
        var proceed = await _ntfsWarning.ShowNtfsWarningAsync(_mainOverlay);
        if (proceed)
        {
            ShowMountOverlay(model);
        }
    }

    private void ShowMountOverlay(FStabModel model)
    {
        DismissMountOverlay();
        
        var backdrop = Box.New(Orientation.Vertical, 0);
        backdrop.SetHexpand(true);
        backdrop.SetVexpand(true);
        backdrop.SetHalign(Align.Fill);
        backdrop.SetValign(Align.Fill);
        backdrop.AddCssClass("overlay-backdrop");
        
        var card = Frame.New(null);
        card.AddCssClass("card");
        card.SetHalign(Align.Center);
        card.SetValign(Align.Center);
        card.SetHexpand(true);
        card.SetVexpand(true);
        card.SetSizeRequest(450, -1);

        var content = Box.New(Orientation.Vertical, 12);
        content.SetMarginTop(20);
        content.SetMarginBottom(20);
        content.SetMarginStart(20);
        content.SetMarginEnd(20);

        var heading = Label.New($"Mount {model.Name}");
        heading.AddCssClass("heading");
        heading.SetXalign(0);
        content.Append(heading);

        var infoBox = Box.New(Orientation.Vertical, 4);
        AddOverlayField(infoBox, "Device", model.Name);
        AddOverlayField(infoBox, "Type", model.FsType);
        AddOverlayField(infoBox, "UUID", model.Uuid);
        content.Append(infoBox);

        var sep = Separator.New(Orientation.Horizontal);
        content.Append(sep);

        var mountLabel = Label.New("Mount Point:");
        mountLabel.SetXalign(0);
        content.Append(mountLabel);

        var homeDir = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var mountEntry = Entry.New();
        mountEntry.SetText($"{homeDir}/mnt/{model.Name}");
        mountEntry.SetHexpand(true);
        content.Append(mountEntry);

        var descLabel = Label.New("Description (optional):");
        descLabel.SetXalign(0);
        content.Append(descLabel);

        var descEntry = Entry.New();
        descEntry.SetPlaceholderText("e.g. Games drive, Backup disk");
        descEntry.SetHexpand(true);
        content.Append(descEntry);

        var optionsLabel = Label.New("Mount Options (optional):");
        optionsLabel.SetXalign(0);
        content.Append(optionsLabel);

        var optionsEntry = Entry.New();
        optionsEntry.SetPlaceholderText("e.g. defaults,noatime,nofail");
        optionsEntry.SetHexpand(true);
        content.Append(optionsEntry);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);
        buttonBox.SetMarginTop(8);

        var cancelButton = Button.NewWithLabel("Cancel");
        cancelButton.OnClicked += (_, _) => DismissMountOverlay();

        var confirmButton = Button.NewWithLabel("Mount");
        confirmButton.AddCssClass("suggested-action");
        confirmButton.OnClicked += (_, _) =>
        {
            var mountPoint = mountEntry.GetText();
            var description = descEntry.GetText();
            var options = optionsEntry.GetText();


            _ = Task.Run(async () =>
            {
                var result =
                    await _privOpService.CreateMountUnitFileAsync(description, model.Uuid, mountPoint, model.FsType,
                        options);
                Console.WriteLine(result.Success
                    ? $"Mount unit created: {result.Output}"
                    : $"Failed to create mount unit: {result.Error}");

                if (result.Success)
                {
                    var unitName = mountPoint.Trim('/').Replace('/', '-') + ".mount";
                    await _privOpService.MountDrives(unitName);
                }
            });

            DismissMountOverlay();
        };

        buttonBox.Append(cancelButton);
        buttonBox.Append(confirmButton);
        content.Append(buttonBox);

        card.SetChild(content);
        backdrop.Append(card);

        _overlayWidget = backdrop;
        _mainOverlay.AddOverlay(backdrop);
    }

    private void DismissMountOverlay()
    {
        if (_overlayWidget == null) return;
        _mainOverlay.RemoveOverlay(_overlayWidget);
        _overlayWidget = null;
    }

    private void OnCredentialRequested(object? sender, CredentialRequestEventArgs e)
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            _passwordDialog.ShowPasswordDialog(_mainOverlay, e.Reason);
            return false;
        });
    }

    private static void AddOverlayField(Box box, string fieldName, string value)
    {
        var hbox = Box.New(Orientation.Horizontal, 6);
        var nameLabel = Label.New(fieldName + ":");
        nameLabel.AddCssClass("dim-label");
        nameLabel.SetXalign(0);
        nameLabel.SetSizeRequest(60, -1);
        var valueLabel = Label.New(value);
        valueLabel.SetXalign(0);
        valueLabel.SetSelectable(true);
        hbox.Append(nameLabel);
        hbox.Append(valueLabel);
        box.Append(hbox);
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