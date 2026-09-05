# Pori
<p align="center">
  <img src="https://github.com/Seafoam-Labs/Pori/raw/master/Pori.Ui/assets/pori.png" alt="Pori Logo" width="128">
</p>

Pori (short for Porifera) is a modern Systemd Mount Manager designed to make mounting drives on Linux simple, reliable, and consistent with system standards.

## Features

* **Systemd Integration**: Create and manage `.mount` units in `/etc/systemd/system/` instead of legacy `/etc/fstab`.
* **Smart Defaults**: Automatically handles proper mount options for various file systems.
* **Native GTK4 interface** written in Zig.
* **D-Bus native**: drive info from UDisks2 and unit state from systemd1 — no CLI scraping.
* **Privileged Operations**: authentication via polkit (`pkexec`) — no passwords in the app.

## Future Features
* Wiping / formatting drives (UDisks2)
* Mounting network devices
* `.automount` (mount on first access) support

## Installation

### Arch Linux

We are avaliable in the CachyOS repos and AUR.

A `PKGBUILD` is provided in the root of the repository. You can build and install it using:

```bash
makepkg -si
```

### Build from Source

**Requirements:**
* Zig 0.16+
* GTK4 development libraries

**Build:**

```bash
cd Pori.Ui
zig build -Doptimize=ReleaseSafe
```

The binary will be available at `Pori.Ui/zig-out/bin/pori` (run with `zig build run` during development).

See [`Pori.Ui/PORTING.md`](Pori.Ui/PORTING.md) for architecture notes, the
D-Bus migration details and the roadmap.

## License

Pori is released under the [GPL-3.0 License](LICENSE).
