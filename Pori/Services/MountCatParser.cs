using Pori.Models;

namespace Pori.Services;

public class MountCatParser : IMountCatParser
{
    public List<string> ParseMountUnitNames(string listUnitsOutput)
    {
        var units = new List<string>();
        if (string.IsNullOrWhiteSpace(listUnitsOutput))
            return units;

        units.AddRange(from line in listUnitsOutput.Split('\n')
            select line.Trim()
            into trimmed
            where !string.IsNullOrWhiteSpace(trimmed)
            select trimmed.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            into parts
            where parts.Length >= 1 && parts[0].EndsWith(".mount", StringComparison.OrdinalIgnoreCase)
            select parts[0]);

        return units;
    }

    public MountCatInfo ParseMountShow(string unitName, string showOutput)
    {
        string description = "", what = "", where = "", type = "", options = "";

        foreach (var line in showOutput.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("Description=", StringComparison.OrdinalIgnoreCase))
                description = trimmed["Description=".Length..].Trim();
            else if (trimmed.StartsWith("What=", StringComparison.OrdinalIgnoreCase))
                what = trimmed["What=".Length..].Trim();
            else if (trimmed.StartsWith("Where=", StringComparison.OrdinalIgnoreCase))
                where = trimmed["Where=".Length..].Trim();
            else if (trimmed.StartsWith("Type=", StringComparison.OrdinalIgnoreCase))
                type = trimmed["Type=".Length..].Trim();
            else if (trimmed.StartsWith("Options=", StringComparison.OrdinalIgnoreCase))
                options = trimmed["Options=".Length..].Trim();
        }

        return new MountCatInfo
        {
            UnitName = unitName,
            Description = description,
            What = what,
            Where = where,
            Type = type,
            Options = options,
        };
    }
}