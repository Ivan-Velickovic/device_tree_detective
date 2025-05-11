I'm not going to lie, I do not like Device Trees.


## linux_compatible_list.txt

Within the root of the Linux source code:
```sh
rg 'compatible.*=.*"(.*)"' -or '$1' drivers/
```

## uboot_compatible_list.txt

Within the root of the U-Boot source code:
```sh
rg 'compatible.*=.*"(.*)"' -or '$1' drivers/
```

## Vendoring cimgui

```sh
wget https://github.com/cimgui/cimgui/archive/refs/heads/docking_inter.zip
unzip docking_inter.zip
mv cimgui-docking_inter/ cimgui
rm docking_inter.zip
cd cimgui
cd imgui
cd .
rm -r imgui
wget https://github.com/ocornut/imgui/archive/4806a1924ff6181180bf5e4b8b79ab4394118875.zip
unzip 4806a1924ff6181180bf5e4b8b79ab4394118875.zip
rm 4806a1924ff6181180bf5e4b8b79ab4394118875.zip
mv imgui-4806a1924ff6181180bf5e4b8b79ab4394118875 imgui
```

## Packaging .deb

```sh
zig build deb
```

## Nix

```sh
nix develop
zig build -Doptimize=ReleaseSafe
```

```sh
nix build .
```
