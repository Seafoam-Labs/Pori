using Gtk;

namespace Pori.Helpers;

public static class MountOptionBuilder
{
    private record MountOption(string Option, string Description, bool Selected = true);

    private static readonly Dictionary<string, List<MountOption>> FsOptions = new(StringComparer.OrdinalIgnoreCase)
    {
        ["btrfs"] =
        [
            new MountOption("defaults", "Use default mount options"),
            new MountOption("compress=zstd:3", "Reduces file sizes and increases lifespan of flash-based media"),
            new MountOption("noatime", "Improves performance and reduces writes to the drive"),
            new MountOption("autodefrag", "Keeps data ordered closely on the platter (beneficial for HDDs)"),
            new MountOption("discard", "Frees unused blocks on SSDs for better write performance"),
            new MountOption("noacl", "Reduces metadata overhead by disabling extended permissions"),
            new MountOption("ssd_spread", "Optimizes allocation for low-end SSDs"),
            new MountOption("nosuid", "Security"),
            new MountOption("nodev", "Security")
        ],
        ["ext4"] =
        [
            new MountOption("defaults", "Use default mount options"),
            new MountOption("noatime", "Improves performance and reduces writes to the drive"),
            new MountOption("errors=remount-ro", "Remounts the filesystem as read-only in case of errors"),
            new MountOption("discard", "Frees unused blocks on SSDs for better write performance"),
            new MountOption("nosuid", "Security"),
            new MountOption("nodev", "Security")
        ],
        ["exfat"] =
        [
            new MountOption("defaults", "Use default mount options"),
            new MountOption("uid=$UID", "Mount with your user permissions"),
            new MountOption("gid=$GID", "Mount with your user group permissions"),
            new MountOption("sync", "Forces all write operations to be flushed immediately")
        ],
        ["udf"] =
        [
            new MountOption("defaults", "Use default mount options"),
            new MountOption("unhide", "Show otherwise hidden files"),
            new MountOption("uid=$UID", "Mount with your user permissions"),
            new MountOption("gid=$GID", "Mount with your user group permissions"),
            new MountOption("noatime", "Improves performance and reduces writes to the drive"),
            new MountOption("nosuid", "Security"),
            new MountOption("nodev", "Security")
        ],
        ["ntfs"] =
        [
            new MountOption("defaults", "Use default mount options"),
            new MountOption("windows_names", "Only allow Windows-compliant file names"),
            new MountOption("uid=$UID", "Mount with your user permissions"),
            new MountOption("gid=$GID", "Mount with your user group permissions"),
            new MountOption("nosuid", "Prevents execution of set-user/group-ID programs (security)"),
            new MountOption("nodev", "Prevents interpretation of block/character devices (security)"),
            new MountOption("umask=022", "Sets standard file/directory permissions (rw-r--r-- / rwxr-xr-x)")
        ],
        ["zfs"] =
        [
            new MountOption("defaults", "Use default mount options"),
        ]
    };

    /// <summary>
    /// Builds a GTK Box containing checkboxes for the given filesystem type.
    /// All options are enabled by default. Returns null if no options exist for the filesystem.
    /// </summary>
    public static Box? BuildOptionsBox(string fsType, out List<(CheckButton Check, string Option)> checkButtons)
    {
        checkButtons = [];

        if (!FsOptions.TryGetValue(fsType, out var options) || options.Count == 0)
            return null;

        var box = Box.New(Orientation.Vertical, 4);

        foreach (var opt in options)
        {
            var resolvedOption = ResolveOption(opt.Option);

            var checkBox = CheckButton.New();
            checkBox.SetActive(opt.Selected);

            var label = Label.New(null);
            label.SetMarkup($"<b>{opt.Option}</b> — {opt.Description}");
            label.SetWrap(true);
            label.SetXalign(0);

            var row = Box.New(Orientation.Horizontal, 8);
            row.Append(checkBox);
            row.Append(label);

            box.Append(row);
            checkButtons.Add((checkBox, resolvedOption));
        }

        return box;
    }

    /// <summary>
    /// Collects the selected mount options into a comma-separated string.
    /// </summary>
    public static string GetSelectedOptions(List<(CheckButton Check, string Option)> checkButtons)
    {
        var selected = checkButtons
            .Where(cb => cb.Check.GetActive())
            .Select(cb => cb.Option);
        return string.Join(",", selected);
    }

    private static string ResolveOption(string option)
    {
        if (option.Contains("$UID"))
        {
            var realUid = GetCurrentUid();
            option = option.Replace("$UID", realUid);
        }

        if (!option.Contains("$GID")) return option;
        var realGid = GetCurrentGid();
        option = option.Replace("$GID", realGid);

        return option;
    }

    private static string GetCurrentUid()
    {
        try
        {
            var uid = Environment.GetEnvironmentVariable("UID");
            if (!string.IsNullOrEmpty(uid)) return uid;

            // fallback: call id -u
            var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "id",
                Arguments = "-u",
                RedirectStandardOutput = true,
                UseShellExecute = false
            });
            process?.WaitForExit();
            return process?.StandardOutput.ReadToEnd().Trim() ?? "1000";
        }
        catch
        {
            return "1000";
        }
    }

    private static string GetCurrentGid()
    {
        try
        {
            var gid = Environment.GetEnvironmentVariable("GID");
            if (!string.IsNullOrEmpty(gid)) return gid;

            var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = "id",
                Arguments = "-g",
                RedirectStandardOutput = true,
                UseShellExecute = false
            });
            process?.WaitForExit();
            return process?.StandardOutput.ReadToEnd().Trim() ?? "1000";
        }
        catch
        {
            return "1000";
        }
    }
}
