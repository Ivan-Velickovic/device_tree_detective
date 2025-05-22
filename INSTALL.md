# Building from source

Building from source is supported macOS and Linux.

There are two system dependencies to build Device Tree Detective:

* Zig (0.14.0)
* pkg-config

Below are environment specific instructions.

## Linux

### Ubuntu/Debian

For installing Zig I would recommend just downloading the binary from https://ziglang.org/download/
and using that.

```sh
sudo apt-get install libxkbcommon-dev xorg-dev libgtk-3-dev pkg-config
```

## Nix/NixOS

You have two options on Nix, either build the package or enter the Nix
development shell and build from there.

To build the package:
```sh
nix build .
```

To use the development shell
```sh
nix develop
zig build
```

## macOS

```sh
brew install zig
```
