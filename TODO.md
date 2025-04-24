## Main work

* [ ] CPU info display
* [ ] Splash/welcome screen
* [ ] Finish tree view
* [ ] Better IRQ view
    * Each IRQ controller needs to know what IRQs map to it. We then draw a line for
      each IRQ/device that is connected to the IRQ controller.
* [ ] Better memory view, introduce memory map probably

## Improvements and QoL

* [ ] Need to handle recently opened files no longer existing on the file system
* [ ] On macOS, Window loses focus after closing file picker, not sure why
* [ ] Linux device tree bindings map/link for a compatible string
* [ ] Goto parent node
* [ ] Goto interrupt-parent node, etc
* [ ] keep track of last opened DTB?
* [ ] import Linux at runtime and have it search that directroy for the list?
    * I would need to recursively iterate through every file, read all the contents
      and then match on the pattern
* [ ] compile DTS to DTB on demand
* [ ] live-reload if the DTB is edited/updated?
* [ ] multiple DTBs open at the same time via tabs
    * [ ] almost done, just need to have proper menu for switching between tabs
* [ ] IRQ info based on GIC etc
* [ ] In platform info show what RISC-V extensions a CPU supports in a nice way
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

```
: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
error: GLFW Error '65544'': Cocoa: Failed to query display mode
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