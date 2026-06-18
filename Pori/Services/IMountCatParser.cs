using Pori.Models;

namespace Pori.Services;

public interface IMountCatParser
{
    MountCatInfo ParseMountShow(string unitName, string showOutput);
    List<string> ParseMountUnitNames(string listUnitsOutput);
}
