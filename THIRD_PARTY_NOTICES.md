# Third-Party Notices

This driver was developed with the Linux r8169 driver from Linux 6.6 and the
Realtek r8168 vendor driver as documented design references. Both upstream
sources identify their relevant driver material as GPL-2.0.

The file `src/rtl8168_firmware_tables.zig` contains firmware/register
tables mechanically extracted from the GPL-2.0-only Realtek vendor driver
`r8168_n.c`. Those tables, the generator that describes the extraction,
and binary artifacts containing them must be treated as GPL-2.0-only material.
The complete GPL version 2 text is provided in
`LICENSE-GPL-2.0-only.txt`.

Original R4OS code in this repository remains licensed under Apache License
2.0. Consumers who redistribute `RTL8168.R4D` must preserve this license
boundary and the GPL notice.

Reference sources:

- Linux r8169 v6.6: https://github.com/torvalds/linux/tree/v6.6/drivers/net/ethernet/realtek
- Realtek r8168 mirror used by the original analysis: https://github.com/mtorromeo/r8168
