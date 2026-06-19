using Pori.Models;

namespace Pori.Services;

public interface IMountCatParser
{
    MountCatInfo ParseMountCat(string unitName, string catOutput);
    List<string> ParseMountUnitNames(string listUnitsOutput);
}
