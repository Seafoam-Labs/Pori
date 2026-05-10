using Gtk;
using Microsoft.Extensions.DependencyInjection;
using Sponge;
using Sponge.Helpers;
using Sponge.Windows;
using GtkSettings = Gtk.Settings;

sealed class Program
{
    [System.Runtime.InteropServices.DllImport("libc")]
    private static extern int getuid();

    private static void EnsureSessionEnvironment()
    {
        var uid = getuid();
        
        // 2. DBUS_SESSION_BUS_ADDRESS — dconf needs this to read GSettings
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS")))
        {
            var rd = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
            if (!string.IsNullOrEmpty(rd))
            {
                var sock = $"{rd}/bus";
                if (File.Exists(sock))
                    Environment.SetEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS", $"unix:path={sock}");
            }
        }

        // 3. XDG_DATA_DIRS — needed so GIO finds compiled GSettings schemas + themes
        var dataDirs = Environment.GetEnvironmentVariable("XDG_DATA_DIRS");
        if (string.IsNullOrEmpty(dataDirs) || !dataDirs.Contains("/usr/share"))
        {
            Environment.SetEnvironmentVariable(
                "XDG_DATA_DIRS",
                "/usr/local/share:/usr/share" + (string.IsNullOrEmpty(dataDirs) ? "" : ":" + dataDirs));
        }

        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("XDG_CURRENT_DESKTOP")))
        {
            Environment.SetEnvironmentVariable("XDG_CURRENT_DESKTOP", DesktopDetector.DetectDesktop());
        }


        // 5. Make GIO use dconf instead of falling back to memory backend
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("GSETTINGS_BACKEND")))
            Environment.SetEnvironmentVariable("GSETTINGS_BACKEND", "dconf");
    }

    private static void ApplyKdeGtkTheme()
    {
        // If the user already forced GTK_THEME, respect it.
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("GTK_THEME")))
            return;

        var home = Environment.GetEnvironmentVariable("HOME") ?? "/root";
        string? themeName = null;
        bool preferDark = false;

        // 1. Preferred source: ~/.config/gtk-4.0/settings.ini (written by kde-gtk-config)
        var gtk4Ini = Path.Combine(home, ".config", "gtk-4.0", "settings.ini");
        if (File.Exists(gtk4Ini))
        {
            foreach (var raw in File.ReadAllLines(gtk4Ini))
            {
                var line = raw.Trim();
                if (line.StartsWith("gtk-theme-name", StringComparison.Ordinal))
                    themeName = ValueAfterEquals(line);
                else if (line.StartsWith("gtk-application-prefer-dark-theme", StringComparison.Ordinal))
                {
                    var v = ValueAfterEquals(line);
                    preferDark = v is "1" or "true" or "True";
                }
            }
        }

        // 2. Fallback: detect dark from kdeglobals ColorScheme
        if (!preferDark)
        {
            var kdeGlobals = Path.Combine(home, ".config", "kdeglobals");
            if (File.Exists(kdeGlobals))
            {
                foreach (var raw in File.ReadAllLines(kdeGlobals))
                {
                    var line = raw.Trim();
                    if (line.StartsWith("ColorScheme=", StringComparison.Ordinal))
                    {
                        var scheme = line["ColorScheme=".Length..];
                        if (scheme.Contains("Dark", StringComparison.OrdinalIgnoreCase))
                            preferDark = true;
                        break;
                    }
                }
            }
        }

        if (string.IsNullOrEmpty(themeName))
            themeName = "Adwaita";

        var full = preferDark ? $"{themeName}:dark" : themeName;
        Environment.SetEnvironmentVariable("GTK_THEME", full);
        Environment.SetEnvironmentVariable("GTK_APPLICATION_PREFER_DARK_THEME", preferDark ? "1" : "0");
    }

    private static string? ValueAfterEquals(string line)
    {
        var i = line.IndexOf('=');
        return i < 0 ? null : line[(i + 1)..].Trim().Trim('"', '\'');
    }

    public static int Main(string[] args)
    {
        EnsureSessionEnvironment();
        if (DesktopDetector.DetectDesktop() == "KDE")
        {
            ApplyKdeGtkTheme();
        }

        var preferDark = false;
        if (DesktopDetector.DetectDesktop() == "GNOME")
        {
            Gio.Module.Initialize();
            var s = Gio.Settings.New("org.gnome.desktop.interface");
            var scheme = s.GetString("color-scheme");
            preferDark = string.Equals(scheme, "prefer-dark", StringComparison.OrdinalIgnoreCase);

            Environment.SetEnvironmentVariable(
                "GTK_APPLICATION_PREFER_DARK_THEME", preferDark ? "1" : "0");
        }

        Module.Initialize();
        if (preferDark)
        {
            var settings = GtkSettings.GetDefault();
            settings?.GtkApplicationPreferDarkTheme = true;
        }


        ServiceCollection serviceCollection = new();
        var serviceProvider = ServiceBuilder.CreateDependencyInjection(serviceCollection);

        var application = Application.New(SpongeConstants.Service,
            Gio.ApplicationFlags.DefaultFlags | Gio.ApplicationFlags.HandlesCommandLine);

        application.OnCommandLine += (sender, e) =>
        {
            application.Activate();
            return 0;
        };


        application.OnActivate += (sender, _) =>
        {
            var existingWindow = application.GetActiveWindow();
            if (existingWindow != null)
            {
                existingWindow.Present();
                return;
            }

            var cssProvider = CssProvider.New();
            cssProvider.LoadFromString(ResourceHelper.LoadAsset("Assets/style.css"));
            StyleContext.AddProviderForDisplay(Gdk.Display.GetDefault()!, cssProvider, 600);

            var iconTheme = IconTheme.GetForDisplay(Gdk.Display.GetDefault()!);
            iconTheme.AddSearchPath("Assets/svg");

            var mainWindow = serviceProvider.GetRequiredService<MainWindow>();
            mainWindow.Show(application);
        };

        return application.Run(args);
    }
}