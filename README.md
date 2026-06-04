# Pori
<p align="center">
  <img src="https://github.com/Seafoam-Labs/Pori/raw/master/Pori/Assets/Pori.png" alt="Pori Logo" width="128">
</p>

Pori (short for Porifera) is a modern Systemd Mount Manager designed to make mounting drives on Linux simple, reliable, and consistent with system standards.

## Features

* **Systemd Integration**: Create and manage `.mount` units in `/etc/systemd/system/` instead of legacy `/etc/fstab`.
* **Smart Defaults**: Automatically handles proper mount options for various file systems.
* **Desktop Integration**: 
  * Native GTK4 interface.
* **Privileged Operations**: Securely handles root-level operations via `sudo`.

## Future Features
* Editing mounts and mount options
* Removing Mounts
* Mounting Network devices

## Installation

### Arch Linux

We are avaliable in the CachyOS repos and AUR.

A `PKGBUILD` is provided in the root of the repository. You can build and install it using:

```bash
makepkg -si
```

### Build from Source

**Requirements:**
* .NET 10.0 SDK
* GTK4 development libraries
* clang (for AOT compilation)

**Build:**

```bash
dotnet publish Pori/Pori.csproj -c Release -r linux-x64 -o out
```

The binary will be available in the `out/` directory.

## License

Pori is released under the [GPL-3.0 License](LICENSE).
