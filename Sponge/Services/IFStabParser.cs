using Sponge.Models;

namespace Sponge.Services;

public interface IFStabParser
{
    List<FStabModel> Parse(string output);
}
