## linux_compatible_list.txt

Within the root of the Linux source code:
```sh
rg 'compatible.*=.*"(.*)"' -or '$1' drivers/
```
