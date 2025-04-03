* [x] main memory
* [x] U-Boot driver for a specific device
* [x] Linux driver for a specific device
    * [ ] import Linux at runtime and have it search that directroy for the list?
        * I would need to recursively iterate through every file, read all the contents
          and then match on the pattern
* [ ] compile DTS to DTB on demand
* [ ] fuzzy search for nodes
* [ ] cpu info
* [ ] irqs top-down view/list
* [ ] live-reload if the DTB is edited/updated?
* [ ] multiple DTBs open at the same time via tabs
* [ ] IRQ info based on GIC etc
* [ ] Help menu (point to GitHub as well)
* [ ] opening files
* [ ] heaps of styling to do
* [ ] macOS support
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
* [ ] in selected node, show full path to node rather than just the name
