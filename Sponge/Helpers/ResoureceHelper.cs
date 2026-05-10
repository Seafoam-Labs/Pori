using System.Reflection;

namespace Sponge.Helpers;

public static class ResourceHelper
{
    private static readonly Assembly Assembly = typeof(ResourceHelper).Assembly;

    public static string LoadUiFile(string relativePath)
    {
        var resourceName = "Sponge." + relativePath.Replace('/', '.').Replace('\\', '.');
        using var stream = Assembly.GetManifestResourceStream(resourceName)
                           ?? throw new FileNotFoundException($"Embedded resource not found: {resourceName}");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public static string LoadAsset(string relativePath)
    {
        return LoadUiFile(relativePath);
    }

    public static Stream GetResourceStream(string relativePath)
    {
        var resourceName = "Sponge." + relativePath.Replace('/', '.').Replace('\\', '.');
        return Assembly.GetManifestResourceStream(resourceName)
               ?? throw new FileNotFoundException($"Embedded resource not found: {resourceName}");
    }
}