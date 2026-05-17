using Microsoft.Extensions.DependencyInjection;
using Pori.Services;
using Pori.Windows;
using Pori.Windows.Dialog;

namespace Pori;

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