using Pori.Models;

namespace Pori.Services;

public interface IMountFileParser
{
    MountUnitInfo ParseMountUnitStatus(string statusOutput);
}