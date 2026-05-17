using Gtk;
using Pori.Helpers;
using Pori.Models;

namespace Pori.Windows.Dialog;

public record MountDialogResult(string MountPoint, string Description, string Options);

public static class MountOptionsDialog
{
    public static Task<MountDialogResult?> ShowMountOptionsAsync(Overlay parentOverlay, FStabModel model)
    {
        var tcs = new TaskCompletionSource<MountDialogResult?>();

        var background = Box.New(Orientation.Vertical, 0);
        background.AddCssClass("lockout-overlay");
        background.SetHalign(Align.Fill);
        background.SetValign(Align.Fill);

        var baseFrame = Frame.New(null);
        baseFrame.SetHalign(Align.Center);
        baseFrame.SetValign(Align.Center);
        baseFrame.SetHexpand(true);
        baseFrame.SetVexpand(true);
        baseFrame.SetSizeRequest(450, -1);
        baseFrame.SetMarginTop(20);
        baseFrame.SetMarginBottom(20);
        baseFrame.SetMarginStart(20);
        baseFrame.SetMarginEnd(20);
        baseFrame.AddCssClass("background");
        baseFrame.AddCssClass("dialog-overlay");
        baseFrame.SetOverflow(Overflow.Hidden);
        background.Append(baseFrame);

        var content = Box.New(Orientation.Vertical, 12);
        content.SetMarginTop(20);
        content.SetMarginBottom(20);
        content.SetMarginStart(20);
        content.SetMarginEnd(20);
        baseFrame.SetChild(content);

        var heading = Label.New($"Mount {model.Name}");
        heading.AddCssClass("title-4");
        heading.SetXalign(0);
        content.Append(heading);

        var infoBox = Box.New(Orientation.Vertical, 4);
        AddField(infoBox, "Device", model.Name);
        AddField(infoBox, "Type", model.FsType);
        AddField(infoBox, "UUID", model.Uuid);
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

        var optionsLabel = Label.New("Recommended Mount Options:");
        optionsLabel.SetXalign(0);
        content.Append(optionsLabel);

        var optionsBox = MountOptionBuilder.BuildOptionsBox(model.FsType, out var mountCheckButtons);
        if (optionsBox != null)
            content.Append(optionsBox);

        var extraOptionsLabel = Label.New("Additional Options (optional):");
        extraOptionsLabel.SetXalign(0);
        content.Append(extraOptionsLabel);

        var optionsEntry = Entry.New();
        optionsEntry.SetPlaceholderText("e.g. nofail");
        optionsEntry.SetHexpand(true);
        content.Append(optionsEntry);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);
        buttonBox.SetMarginTop(8);

        var cancelButton = Button.NewWithLabel("Cancel");
        cancelButton.OnClicked += (_, _) =>
        {
            parentOverlay.RemoveOverlay(background);
            tcs.TrySetResult(null);
        };

        var confirmButton = Button.NewWithLabel("Mount");
        confirmButton.AddCssClass("suggested-action");
        confirmButton.OnClicked += (_, _) =>
        {
            var mountPoint = mountEntry.GetText();
            var description = descEntry.GetText();
            var checkedOptions = MountOptionBuilder.GetSelectedOptions(mountCheckButtons);
            var extraOptions = optionsEntry.GetText();
            var options = string.IsNullOrWhiteSpace(extraOptions)
                ? checkedOptions
                : string.IsNullOrWhiteSpace(checkedOptions)
                    ? extraOptions
                    : $"{checkedOptions},{extraOptions}";

            parentOverlay.RemoveOverlay(background);
            tcs.TrySetResult(new MountDialogResult(mountPoint, description, options));
        };

        buttonBox.Append(cancelButton);
        buttonBox.Append(confirmButton);
        content.Append(buttonBox);

        parentOverlay.AddOverlay(background);

        return tcs.Task;
    }

    private static void AddField(Box box, string fieldName, string value)
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
}
