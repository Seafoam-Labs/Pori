using Microsoft.Extensions.DependencyInjection;
using Sponge.Services;
using Sponge.Windows;
using Sponge.Windows.Dialog;

namespace Sponge;

public static class ServiceBuilder
{
    public static ServiceProvider CreateDependencyInjection(ServiceCollection collection)
    {
        collection.AddTransient<MainWindow>();
        collection.AddTransient<IFStabParser, FStabParser>();
        collection.AddTransient<IUnPrivOpService, UnPrivOpService>();
        collection.AddTransient<IPrivOpService, PrivOpService>();
        collection.AddSingleton<ICredentialManager, CredentialManager>();
        collection.AddTransient<PasswordDialog>();
        return collection.BuildServiceProvider();
    }
}