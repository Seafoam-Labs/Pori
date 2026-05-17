using Pori.Models;

namespace Pori.Services;

public class FStabParser : IFStabParser
{
    public List<FStabModel> Parse(string output)
    {
        var results = new List<FStabModel>();
        var lines = output.Split('\n');

        if (lines.Length < 2)
            return results;

        var header = lines[0];

        var nameStart = header.IndexOf("NAME", StringComparison.Ordinal);
        var fsTypeStart = header.IndexOf("FSTYPE", StringComparison.Ordinal);
        var fsVerStart = header.IndexOf("FSVER", StringComparison.Ordinal);
        var labelStart = header.IndexOf("LABEL", StringComparison.Ordinal);
        var uuidStart = header.IndexOf("UUID", StringComparison.Ordinal);
        var fsAvailStart = header.IndexOf("FSAVAIL", StringComparison.Ordinal);
        var fsUseStart = header.IndexOf("FSUSE%", StringComparison.Ordinal);
        var mountStart = header.IndexOf("MOUNTPOINTS", StringComparison.Ordinal);

        int[] starts = [nameStart, fsTypeStart, fsVerStart, labelStart, uuidStart, fsAvailStart, fsUseStart, mountStart];

        for (var i = 1; i < lines.Length; i++)
        {
            var line = lines[i];
            if (string.IsNullOrWhiteSpace(line))
                continue;

            results.Add(new FStabModel
            {
                Name = ExtractField(line, starts, 0).Replace("├─", "").Replace("└─", "").Replace("│ ", ""),
                FsType = ExtractField(line, starts, 1),
                Fsver = ExtractField(line, starts, 2),
                Label = ExtractField(line, starts, 3),
                Uuid = ExtractField(line, starts, 4),
                FSavail = ExtractField(line, starts, 5),
                FSused = ExtractField(line, starts, 6),
                MountPoints = ExtractField(line, starts, 7),
            });
        }

        return results;
    }

    private static string ExtractField(string line, int[] starts, int index)
    {
        if (starts[index] < 0 || starts[index] >= line.Length)
            return string.Empty;

        var start = starts[index];
        var end = index + 1 < starts.Length && starts[index + 1] >= 0
            ? starts[index + 1]
            : line.Length;

        if (start >= line.Length)
            return string.Empty;

        end = Math.Min(end, line.Length);

        return line[start..end].Trim();
    }
}
