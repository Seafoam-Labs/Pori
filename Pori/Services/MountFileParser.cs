using Pori.Models;

namespace Pori.Services;

public class MountFileParser : IMountFileParser
{
    public MountUnitInfo ParseMountUnitStatus(string statusOutput)
    {
        string description = "", what = "", where = "", active = "";
        if (string.IsNullOrWhiteSpace(statusOutput))
            return new MountUnitInfo { Description = description, What = what, Where = where, Active = active };
        foreach (var line in statusOutput.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith($"●") && trimmed.Contains(" - "))
                description = trimmed[(trimmed.IndexOf(" - ", StringComparison.Ordinal) + 3)..].Trim();
            else if (trimmed.StartsWith("Active:", StringComparison.OrdinalIgnoreCase))
                active = trimmed["Active:".Length..].Trim();
            else if (trimmed.StartsWith("Where:", StringComparison.OrdinalIgnoreCase))
                where = trimmed["Where:".Length..].Trim();
            else if (trimmed.StartsWith("What:", StringComparison.OrdinalIgnoreCase))
                what = trimmed["What:".Length..].Trim();
        }
        return new MountUnitInfo { Description = description, What = what, Where = where, Active = active };
    }
}