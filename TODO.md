## Plan

* I really want to finish this by next Wednesday, which means I have one full week.
* There's still lots of polish and features to implement.
* I think until the end of this week I should finish the main features I want to ship.
* Then spend 3 days working on packaging everything and polishing it.

## Main work

* [ ] CPU info display
* [ ] Splash/welcome screen
* [ ] Finish tree view
* [ ] Better IRQ view
    * Each IRQ controller needs to know what IRQs map to it. We then draw a line for
      each IRQ/device that is connected to the IRQ controller.
* [ ] Better memory view, introduce memory map probably

## Improvements and QoL

* [ ] In IRQ canvas view, group IRQ lines by device
* [ ] display each parent of the full node name as a box that can be clicked on to
      select that node?
* [ ] Linux CMA memory?
* [ ] Search by phandle?
* [ ] Memory regions list should definitely be represented as a table instead
* [ ] When filtering an example DTB, selection is still clunky and does not work that well.
* [ ] When filtering on the tree view, we should be looking at the expanded tree view
      of the parent nodes I think e.g the 'soc' node should also show up when we search 'ethernet'
* [ ] Having multiple windows vs having multiple open files?
    * If people open multiple instances of the application, we have issues with saving the
      user-configuration since now there's concurrent access.
      How does Sublime Text do this? Where you can open multiple windows but it's the same app
      instance?
* [ ] Need to handle recently opened files no longer existing on the file system
* [ ] On macOS, Window loses focus after closing file picker, not sure why
* [ ] Linux device tree bindings map/link for a compatible string
    * [ ] Need to finish a proper script to do this. zig-yaml does not work for
          some reason so maybe we need to stick with Python.
* [ ] Goto parent node
* [ ] Goto interrupt-parent node, etc
* [ ] import Linux at runtime and have it search that directroy for the list?
    * I would need to recursively iterate through every file, read all the contents
      and then match on the pattern
* [ ] compile DTS to DTB on demand
* [ ] live-reload if the DTB is edited/updated?
* [ ] multiple DTBs open at the same time via tabs
    * almost done, just need to have proper menu for switching between tabs
* [ ] IRQ info based on GIC etc
* [ ] list lists of strings as a drop-down in the 'selected node' view
* [ ] dtb properites to parse
    * [ ] interrupt-map
    * [ ] interrupts-extended
    * [ ] bus-range
    * [ ] linux,pci-domain
    * [ ] interrupt-map-mask
    * [ ] bank-width
    * [ ] riscv,event-to-mhpmcounters
    * [ ] migrate, cpu_on, cpu_off, cpu_suspend
* [ ] display status = disabled or status = okay nicely
* [ ] proper logo
* [ ] click on addresses or interrupts to copy them to clipboard
* [ ] memory view, e.g let's say i just have an address and need to find the
      coressponding device
* [ ] check compatible map, arm,cortex-a55 was coming with imx uboot cpu driver
* [ ] some colours are still messed up
* [ ] Window/Dock icon needs to be sorted out on a per-OS basis.
    * [ ] On Linux, alt-tab does not show the icon, but the dock shows the icon
    * [ ] macOS icon is way too big
* [ ] DTB seems to crash on certain Linux DTBs, should have a test that goes
      through all the example DTBs and tries to parse them.
* [ ] Resizable windows - see child windows section of demo
* [ ] paths should be prefixed with ~ rather than /Users/ivanv/ or /home/ivanv etc
* [ ] native menu bar for macOS

```
info: using existing user configuration 'user.json'
thread 2002631 panic: integer cast truncated bits
/Users/ivanv/dev/device_tree_detective/src/main.zig:595:25: 0x104a89653 in regionsAdd (Device Tree Detective)
                .addr = @intCast(r[0]),
                        ^
/Users/ivanv/dev/device_tree_detective/src/main.zig:589:23: 0x104a8951f in regionsAdd (Device Tree Detective)
        try regionsAdd(child, regions);
                      ^
/Users/ivanv/dev/device_tree_detective/src/main.zig:589:23: 0x104a8951f in regionsAdd (Device Tree Detective)
        try regionsAdd(child, regions);
                      ^
/Users/ivanv/dev/device_tree_detective/src/main.zig:589:23: 0x104a8951f in regionsAdd (Device Tree Detective)
        try regionsAdd(child, regions);
                      ^
/Users/ivanv/dev/device_tree_detective/src/main.zig:589:23: 0x104a8951f in regionsAdd (Device Tree Detective)
        try regionsAdd(child, regions);
                      ^
/Users/ivanv/dev/device_tree_detective/src/main.zig:589:23: 0x104a8951f in regionsAdd (Device Tree Detective)
        try regionsAdd(child, regions);
                      ^
/Users/ivanv/dev/device_tree_detective/src/main.zig:544:23: 0x104a8d983 in init (Device Tree Detective)
        try regionsAdd(root, &regions);
                      ^
/Users/ivanv/dev/device_tree_detective/src/main.zig:175:43: 0x104a8f86b in loadPlatform (Device Tree Detective)
        const platform = try Platform.init(s.allocator, path);
                                          ^
/Users/ivanv/dev/device_tree_detective/src/main.zig:1324:35: 0x104a96f63 in main (Device Tree Detective)
            try state.loadPlatform(d);
                                  ^
/Users/ivanv/zigs/zig-macos-aarch64-0.14.0/lib/std/start.zig:656:37: 0x104a9cadb in main (Device Tree Detective)
            const result = root.main() catch |err| {
                                    ^
???:?:?: 0x188dd2b4b in ??? (???)
???:?:?: 0x0 in ??? (???)
run
```

```
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Cannot query workarea without screen
error: GLFW Error '65544'': Cocoa: Cannot query content scale without screen
Assertion failed: (new_dpi_scale > 0.0f && new_dpi_scale < 99.0f), function UpdateViewportsNewFrame, file imgui.cpp, line 16029.
run
└─ run dtb_viewer failure
error: the following command terminated unexpectedly:
/Users/ivanv/dev/dtb_viewer/zig-out/bin/dtb_viewer dtbs/sel4/odroidc4.dtb
Build Summary: 3/5 steps succeeded; 1 failed
run transitive failure
└─ run dtb_viewer failure
error: the following build command failed with exit code 1:
/Users/ivanv/dev/dtb_viewer/.zig-cache/o/3aa2679eac9fdc05d9bbba627e0600d0/build /Users/ivanv/zigs/zig-macos-aarch64-0.15.0-dev.155+acfdad858/zig /Users/ivanv/zigs/zig-macos-aarch64-0.15.0-dev.155+acfdad858/lib /Users/ivanv/dev/dtb_viewer /Users/ivanv/dev/dtb_viewer/.zig-cache /Users/iv
```

```
device_tree_detective/packaging [main*] :: sudo apt remove devicetreedetective                       
[sudo] password for ivanv:      
Sorry, try again.
[sudo] password for ivanv:                
Reading package lists... Done
Building dependency tree... Done
Reading state information... Done
The following packages were automatically installed and are no longer required:
  liblldb-15 libllvm13 libwpe-1.0-1 libwpebackend-fdo-1.0-1 pantheon-agent-geoclue2
Use 'sudo apt autoremove' to remove them.
The following packages will be REMOVED:
  devicetreedetective
0 upgraded, 0 newly installed, 1 to remove and 350 not upgraded.
After this operation, 0 B of additional disk space will be used.
Do you want to continue? [Y/n] 
(Reading database ... 238405 files and directories currently installed.)
Removing devicetreedetective (0.1.0) ...
dpkg: warning: while removing devicetreedetective, directory '/usr/local/share' not empty so not removed
dpkg: warning: while removing devicetreedetective, directory '/usr/local/bin' not empty so not removed
Processing triggers for hicolor-icon-theme (0.17-2) ...
```

On a macOS virtual machine:
```
NSGL: Failed to find a suitable pixel format
GLFW decided not to create a window
```

## Releasing

1. Package macOS binary
    * Understand .app vs .dmg etc
    * Figure out XCode project stuff
    * Notarise/sign
2. Package Debian binary
    * Not sure how to manage control files, maybe we should auto-generate them
      by Zig build? Not sure.
    * Need to figure out .desktop files.
3. Windows binary
    * Have no idea how to properly go about linking GLFW
