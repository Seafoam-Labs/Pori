using Pori.Models;

namespace Pori.Services;

public interface IFStabParser
{
    List<FStabModel> Parse(string output);
}
