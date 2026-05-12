using Gtk;

namespace Sponge.Windows.Dialog;

public static class NtfsWarning
{
    public static Task<bool> ShowNtfsWarningAsync(Overlay parentOverlay)
    {
        var tcs = new TaskCompletionSource<bool>();

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

        var box = Box.New(Orientation.Vertical, 12);
        box.SetMarginTop(20);
        box.SetMarginBottom(20);
        box.SetMarginStart(20);
        box.SetMarginEnd(20);
        baseFrame.SetChild(box);

        var titleLabel = Label.New("⚠ NTFS Compatibility Warning");
        titleLabel.AddCssClass("title-4");
        box.Append(titleLabel);

        var message = Label.New(
            "Linux does not have full native support for NTFS. " +
            "While mounting is possible you may experience issues.\n\n" +
            "Especially if trying to mount an NTFS drive and play games off steam " +
            "It is recommended to back up important and reformat the drive to a format like ext4.");
        message.SetWrap(true);
        message.SetXalign(0);
        box.Append(message);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);
        buttonBox.SetMarginTop(8);

        var cancelButton = Button.NewWithLabel("Cancel");
        cancelButton.OnClicked += (_, _) =>
        {
            parentOverlay.RemoveOverlay(background);
            tcs.TrySetResult(false);
        };

        var proceedButton = Button.NewWithLabel("Proceed Anyway");
        proceedButton.AddCssClass("destructive-action");
        proceedButton.OnClicked += (_, _) =>
        {
            parentOverlay.RemoveOverlay(background);
            tcs.TrySetResult(true);
        };

        buttonBox.Append(cancelButton);
        buttonBox.Append(proceedButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(background);

        return tcs.Task;
    }
}
