const std = @import("std");

pub const vendor_realtek: u16 = 0x10EC;
pub const device_rtl8168: u16 = 0x8168;
pub const target_subsystem_vendor: u16 = 0x17AA;
pub const target_subsystem_device: u16 = 0x38C7;
pub const target_revision: u8 = 0x10;

pub const descriptor_owned: u32 = 1 << 31;
pub const descriptor_end_of_ring: u32 = 1 << 30;
pub const descriptor_first_segment: u32 = 1 << 29;
pub const descriptor_last_segment: u32 = 1 << 28;
pub const descriptor_length_mask: u32 = 0x3FFF;
pub const rx_error_summary: u32 = 1 << 21;
pub const tx_error_summary: u32 = 1 << 23;
pub const rtl8168h_eee_txidle: u16 = 1500 + 14 + 0x20;

pub const Descriptor = extern struct {
    opts1: u32 = 0,
    opts2: u32 = 0,
    addr: u64 = 0,
};

pub const PhyFamily = enum {
    phyar,
    gphy_ocp,
    preserve_firmware,
};

pub const EphyPatch = struct {
    register: u5,
    clear_mask: u16,
    set_bits: u16,
};

pub const rtl8168h_ephy_baseline = [_]EphyPatch{
    .{ .register = 0x1E, .clear_mask = 0x0800, .set_bits = 0x0001 },
    .{ .register = 0x1D, .clear_mask = 0x0000, .set_bits = 0x0800 },
    .{ .register = 0x05, .clear_mask = 0xFFFF, .set_bits = 0x2089 },
    .{ .register = 0x06, .clear_mask = 0xFFFF, .set_bits = 0x5881 },
    .{ .register = 0x04, .clear_mask = 0xFFFF, .set_bits = 0x854A },
    .{ .register = 0x01, .clear_mask = 0xFFFF, .set_bits = 0x068B },
};

// Upstream e_info_8168g_2 (r8169 v6.6) fuer VER_42 = RTL8168GU, XID 0x509:
// die exakte EPHY-Baseline des realen Lenovo-Ziels.
pub const rtl8168g2_ephy_baseline = [_]EphyPatch{
    .{ .register = 0x00, .clear_mask = 0x0008, .set_bits = 0x0000 },
    .{ .register = 0x0C, .clear_mask = 0x3FF0, .set_bits = 0x0820 },
    .{ .register = 0x19, .clear_mask = 0xFFFF, .set_bits = 0x7C00 },
    .{ .register = 0x1E, .clear_mask = 0xFFFF, .set_bits = 0x20EB },
    .{ .register = 0x0D, .clear_mask = 0xFFFF, .set_bits = 0x1666 },
    .{ .register = 0x00, .clear_mask = 0xFFFF, .set_bits = 0x10A3 },
    .{ .register = 0x06, .clear_mask = 0xFFFF, .set_bits = 0xF050 },
    .{ .register = 0x04, .clear_mask = 0x0000, .set_bits = 0x0010 },
    .{ .register = 0x1D, .clear_mask = 0x4000, .set_bits = 0x0000 },
};

const XidPattern = struct {
    mask: u16,
    value: u16,
};

const gphy_ocp_patterns = [_]XidPattern{
    .{ .mask = 0x7CF, .value = 0x4C0 },
    .{ .mask = 0x7CF, .value = 0x509 },
    .{ .mask = 0x7CF, .value = 0x5C8 },
    .{ .mask = 0x7CF, .value = 0x541 },
    .{ .mask = 0x7CF, .value = 0x6C0 },
    .{ .mask = 0x7CF, .value = 0x502 },
    .{ .mask = 0x7CF, .value = 0x54A },
    .{ .mask = 0x7CF, .value = 0x54B },
};

const phyar_patterns = [_]XidPattern{
    .{ .mask = 0x7C8, .value = 0x380 },
    .{ .mask = 0x7CF, .value = 0x3C9 },
    .{ .mask = 0x7CF, .value = 0x3C8 },
    .{ .mask = 0x7C8, .value = 0x3C8 },
    .{ .mask = 0x7CF, .value = 0x3C0 },
    .{ .mask = 0x7CF, .value = 0x3C2 },
    .{ .mask = 0x7CF, .value = 0x3C3 },
    .{ .mask = 0x7C8, .value = 0x3C0 },
    .{ .mask = 0x7CF, .value = 0x281 },
    .{ .mask = 0x7C8, .value = 0x280 },
    .{ .mask = 0x7CF, .value = 0x2C1 },
    .{ .mask = 0x7C8, .value = 0x2C0 },
    .{ .mask = 0x7C8, .value = 0x2C8 },
    .{ .mask = 0x7CF, .value = 0x481 },
    .{ .mask = 0x7CF, .value = 0x480 },
    .{ .mask = 0x7C8, .value = 0x488 },
};

pub fn xidFromTxConfig(tx_config: u32) u16 {
    return @truncate((tx_config >> 20) & 0xFCF);
}

pub fn phyFamilyForXid(xid: u16) PhyFamily {
    // Match the same don't-care bits as the upstream chip table. Bit 11 is
    // not part of either family identity, and several older revisions also
    // leave low revision bits unspecified through mask 0x7c8.
    for (gphy_ocp_patterns) |pattern| {
        if ((xid & pattern.mask) == pattern.value) return .gphy_ocp;
    }
    for (phyar_patterns) |pattern| {
        if ((xid & pattern.mask) == pattern.value) return .phyar;
    }

    // RTL8168DP has a separate MDIO arbitration sequence. Unknown XIDs are
    // also left on their firmware-programmed PHY state.
    return .preserve_firmware;
}

pub fn isRtl8168H(xid: u16) bool {
    const normalized = xid & 0x7CF;
    return normalized == 0x541 or normalized == 0x6C0;
}

pub fn isRtl8168GFamily(xid: u16) bool {
    // The gphy_ocp identity set is exactly the OOB/shared-FIFO MCU
    // architecture (upstream VER_40 bis VER_53). After a platform reset the
    // firmware owns the FIFO link list until the driver performs the
    // NOW_IS_OOB/link-list handoff; the reset-free minimal bind is only valid
    // for the remaining legacy families.
    return phyFamilyForXid(xid) == .gphy_ocp;
}

pub fn patchedRegisterValue(current: u16, clear_mask: u16, set_bits: u16) u16 {
    return (current & ~clear_mask) | set_bits;
}

pub fn macAddressLow(mac: [6]u8) u32 {
    return @as(u32, mac[0]) |
        (@as(u32, mac[1]) << 8) |
        (@as(u32, mac[2]) << 16) |
        (@as(u32, mac[3]) << 24);
}

pub fn macAddressHigh(mac: [6]u8) u32 {
    return @as(u32, mac[4]) | (@as(u32, mac[5]) << 8);
}

pub fn eriReadCommand(address: u16, byte_enable: u4) ?u32 {
    if ((address & 3) != 0 or address > 0x0FFC or byte_enable == 0) return null;
    return (@as(u32, byte_enable) << 12) | address;
}

pub fn eriWriteCommand(address: u16, byte_enable: u4) ?u32 {
    const read_command = eriReadCommand(address, byte_enable) orelse return null;
    return (@as(u32, 1) << 31) | read_command;
}

pub fn ephyReadCommand(register: u5) u32 {
    return @as(u32, register) << 16;
}

pub fn ephyWriteCommand(register: u5, value: u16) u32 {
    return (@as(u32, 1) << 31) | ephyReadCommand(register) | value;
}

pub fn macOcpReadCommand(register: u16) ?u32 {
    if ((register & 1) != 0) return null;
    return @as(u32, register) << 15;
}

pub fn macOcpWriteCommand(register: u16, value: u16) ?u32 {
    const read_command = macOcpReadCommand(register) orelse return null;
    return (@as(u32, 1) << 31) | read_command | value;
}

pub fn validCapabilityOffset(offset: u8) bool {
    return offset >= 0x40 and offset <= 0xFC and (offset & 3) == 0;
}

pub fn capabilityOffset(raw: u32) u8 {
    return @as(u8, @truncate(raw)) & 0xFC;
}

pub fn nextCapabilityOffset(header: u32) u8 {
    return @as(u8, @truncate(header >> 8)) & 0xFC;
}

pub fn pmD0WriteValue(raw: u32) u32 {
    // State bits 1:0 become D0. PME_Status is W1C, so write zero there.
    return raw & ~@as(u32, 0x0000_8003);
}

pub fn pcieEndpointL1DisabledWriteValue(raw: u32) u32 {
    // Link Control is the lower half word. Link Status is read-only/W1C-like
    // on some revisions, therefore never echo its upper-half read value.
    return (raw & 0x0000_FFFF) & ~@as(u32, 1 << 1);
}

pub fn pciCommandWithoutBusMaster(raw: u32) u32 {
    // PCI Status occupies the upper half and contains write-one-to-clear bits.
    // Never echo it while updating the Command register.
    return (raw & 0x0000_FFFF) & ~@as(u32, 1 << 2);
}

pub fn pciCommandForMemoryOnly(raw: u32) u32 {
    // BAR MMIO must remain decodable during the pre-DMA OOB handoff, but a
    // retained warm-reset engine must not fetch old descriptors. As with all
    // Command writes, never echo the W1C Status half word.
    return ((raw & 0x0000_FFFF) | (1 << 1)) & ~@as(u32, 1 << 2);
}

pub fn cplusCommandForRtl8168(raw: u16) u16 {
    // r8169 snapshots only CPCMD_MASK before the first MAC reset. RTL8168H
    // does not use the legacy PCIDAC/PCIMulRW controls; R4OS also has no RX
    // VLAN/checksum offload contract, so those two features stay disabled.
    const normal_mode: u16 = 1 << 13;
    const rx_vlan: u16 = 1 << 6;
    const rx_checksum: u16 = 1 << 5;
    const interrupt_timer: u16 = 0x0003;
    return (raw & (normal_mode | rx_vlan | rx_checksum | interrupt_timer)) &
        ~(rx_vlan | rx_checksum);
}

pub fn rtl8168AspmEntryLatencyWriteValue(raw: u32) u32 {
    // Realtek extended PCI config byte 0x70f: L0 = 7 us, L1 = 16 us.
    return (raw & 0x00FF_FFFF) | (@as(u32, 0x27) << 24);
}

pub fn rtl8168hAdcBias(data1: u16, data2: u16) u16 {
    var ioffset = (data2 >> 1) & 0x7FF8;
    ioffset |= data2 & 0x0007;
    if ((data1 & (1 << 7)) != 0) ioffset |= 1 << 15;
    return ioffset;
}

pub fn rtl8168hRlenValue(raw: u16) u16 {
    const measured = raw & 0x000F;
    const rlen: u16 = if (measured > 3) measured - 3 else 0;
    return rlen | (rlen << 4) | (rlen << 8) | (rlen << 12);
}

pub fn rtl8168hSawCounterValue(raw: u16) ?u16 {
    const count: u32 = raw & 0x3FFF;
    if (count == 0) return null;
    return @truncate((16_000_000 / count) & 0x0FFF);
}

pub fn rxFrameLength(opts1: u32, buffer_bytes: u32) ?u32 {
    if ((opts1 & descriptor_owned) != 0) return null;
    if ((opts1 & descriptor_first_segment) == 0 or (opts1 & descriptor_last_segment) == 0) return null;
    if ((opts1 & rx_error_summary) != 0) return null;
    const wire_len = opts1 & descriptor_length_mask;
    if (wire_len < 4 or wire_len > buffer_bytes) return null;
    return wire_len - 4; // Hardware includes the Ethernet FCS.
}

pub fn rxOwnedOptions(buffer_bytes: u32, end_of_ring: bool) u32 {
    return descriptor_owned | (buffer_bytes & descriptor_length_mask) |
        (if (end_of_ring) descriptor_end_of_ring else 0);
}

pub fn txOwnedOptions(frame_bytes: u32, end_of_ring: bool) u32 {
    return descriptor_owned | descriptor_first_segment | descriptor_last_segment |
        (frame_bytes & descriptor_length_mask) |
        (if (end_of_ring) descriptor_end_of_ring else 0);
}

pub fn ticksForMilliseconds(frequency: u32, milliseconds: u32) u64 {
    if (milliseconds == 0) return 0;
    const ticks = (@as(u64, frequency) * milliseconds + 999) / 1000;
    return @max(ticks, 1);
}

test "RTL8168 target identity and descriptor contract" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Descriptor));
    try std.testing.expectEqual(@as(u16, 0x541), xidFromTxConfig(0x5410_0000));
    try std.testing.expectEqual(PhyFamily.gphy_ocp, phyFamilyForXid(0x541));
    try std.testing.expectEqual(PhyFamily.gphy_ocp, phyFamilyForXid(0xD41));
    try std.testing.expectEqual(PhyFamily.phyar, phyFamilyForXid(0x481));
    try std.testing.expectEqual(PhyFamily.phyar, phyFamilyForXid(0x287));
    try std.testing.expectEqual(PhyFamily.phyar, phyFamilyForXid(0x48F));
    try std.testing.expectEqual(PhyFamily.preserve_firmware, phyFamilyForXid(0x28A));
    try std.testing.expectEqual(PhyFamily.preserve_firmware, phyFamilyForXid(0x777));

    try std.testing.expect(isRtl8168H(0x541));
    try std.testing.expect(isRtl8168H(0x571));
    try std.testing.expect(isRtl8168H(0xD41));
    try std.testing.expect(isRtl8168H(0x6C0));
    try std.testing.expect(isRtl8168H(0xEC0));
    try std.testing.expect(!isRtl8168H(0x540));
    try std.testing.expect(!isRtl8168H(0x509));
    try std.testing.expect(!isRtl8168H(0x5C8));
    try std.testing.expect(!isRtl8168H(0x502));
    try std.testing.expect(!isRtl8168H(0x777));

    // Reale Lenovo-L340-Hardware: RTL8168GU meldet XID 0x509 und braucht den
    // OOB-/Shared-FIFO-Handoff nach jedem Plattformreset genauso wie H.
    try std.testing.expect(isRtl8168GFamily(0x509));
    try std.testing.expect(isRtl8168GFamily(0x4C0));
    try std.testing.expect(isRtl8168GFamily(0x5C8));
    try std.testing.expect(isRtl8168GFamily(0x541));
    try std.testing.expect(isRtl8168GFamily(0x6C0));
    try std.testing.expect(isRtl8168GFamily(0x502));
    try std.testing.expect(isRtl8168GFamily(0x54A));
    try std.testing.expect(isRtl8168GFamily(0x54B));
    try std.testing.expect(!isRtl8168GFamily(0x481));
    try std.testing.expect(!isRtl8168GFamily(0x540));
    try std.testing.expect(!isRtl8168GFamily(0x777));

    // e_info_8168g_2 (VER_42): neun Patches, Werte exakt nach r8169 v6.6.
    try std.testing.expectEqual(@as(usize, 9), rtl8168g2_ephy_baseline.len);
    try std.testing.expectEqual(@as(u16, 0x7C00), rtl8168g2_ephy_baseline[2].set_bits);
    try std.testing.expectEqual(@as(u16, 0x20EB), rtl8168g2_ephy_baseline[3].set_bits);
    try std.testing.expectEqual(@as(u16, 0x1666), rtl8168g2_ephy_baseline[4].set_bits);
    try std.testing.expectEqual(@as(u16, 0x10A3), rtl8168g2_ephy_baseline[5].set_bits);
    try std.testing.expectEqual(@as(u16, 0xF050), rtl8168g2_ephy_baseline[6].set_bits);
    try std.testing.expectEqual(@as(u5, 0x04), rtl8168g2_ephy_baseline[7].register);
    try std.testing.expectEqual(@as(u16, 0x4000), rtl8168g2_ephy_baseline[8].clear_mask);
}

test "RTL8168H register command and baseline contract" {
    const mac = [6]u8{ 0x98, 0xFA, 0x9B, 0xF8, 0xDD, 0x5D };
    try std.testing.expectEqual(@as(u32, 0xF89B_FA98), macAddressLow(mac));
    try std.testing.expectEqual(@as(u32, 0x0000_5DDD), macAddressHigh(mac));

    try std.testing.expectEqual(@as(u16, 0x1205), patchedRegisterValue(0x12F5, 0x00F0, 0x0005));
    try std.testing.expectEqual(@as(u16, 0x9234), patchedRegisterValue(0x1234, 0x0000, 0x8000));
    try std.testing.expectEqual(@as(u16, 0x068B), patchedRegisterValue(0xFFFF, 0xFFFF, 0x068B));

    try std.testing.expectEqual(@as(?u32, 0x0000_F5F0), eriReadCommand(0x05F0, 0xF));
    try std.testing.expectEqual(@as(?u32, 0x8000_10DC), eriWriteCommand(0x00DC, 0x1));
    try std.testing.expectEqual(@as(?u32, null), eriReadCommand(0x00DD, 0xF));
    try std.testing.expectEqual(@as(?u32, null), eriReadCommand(0x1000, 0xF));
    try std.testing.expectEqual(@as(?u32, null), eriReadCommand(0x00DC, 0));

    try std.testing.expectEqual(@as(u32, 0x001E_0000), ephyReadCommand(0x1E));
    try std.testing.expectEqual(@as(u32, 0x8005_2089), ephyWriteCommand(0x05, 0x2089));
    try std.testing.expectEqual(@as(?u32, 0x7049_0000), macOcpReadCommand(0xE092));
    try std.testing.expectEqual(@as(?u32, 0xF029_8008), macOcpWriteCommand(0xE052, 0x8008));
    try std.testing.expectEqual(@as(?u32, null), macOcpReadCommand(0xE093));

    const expected = [_]EphyPatch{
        .{ .register = 0x1E, .clear_mask = 0x0800, .set_bits = 0x0001 },
        .{ .register = 0x1D, .clear_mask = 0x0000, .set_bits = 0x0800 },
        .{ .register = 0x05, .clear_mask = 0xFFFF, .set_bits = 0x2089 },
        .{ .register = 0x06, .clear_mask = 0xFFFF, .set_bits = 0x5881 },
        .{ .register = 0x04, .clear_mask = 0xFFFF, .set_bits = 0x854A },
        .{ .register = 0x01, .clear_mask = 0xFFFF, .set_bits = 0x068B },
    };
    try std.testing.expectEqualSlices(EphyPatch, &expected, &rtl8168h_ephy_baseline);
}

test "bounded capability and power transforms" {
    try std.testing.expect(validCapabilityOffset(0x40));
    try std.testing.expect(validCapabilityOffset(0xFC));
    try std.testing.expect(!validCapabilityOffset(0x3C));
    try std.testing.expect(!validCapabilityOffset(0x42));
    try std.testing.expectEqual(@as(u8, 0x84), capabilityOffset(0x0000_0087));
    try std.testing.expectEqual(@as(u8, 0xA0), nextCapabilityOffset(0x0000_A010));

    const pm: u32 = 0xABCD_F003;
    try std.testing.expectEqual(@as(u32, 0), pmD0WriteValue(pm) & 3);
    try std.testing.expectEqual(@as(u32, 0), pmD0WriteValue(pm) & 0x8000);

    const link: u32 = 0xA5A5_0003;
    const disabled = pcieEndpointL1DisabledWriteValue(link);
    try std.testing.expectEqual(@as(u32, 1), disabled & 1); // preserve L0s
    try std.testing.expectEqual(@as(u32, 0), disabled & 2); // disable L1 only
    try std.testing.expectEqual(@as(u32, 0), disabled & 0xFFFF_0000);

    const command: u32 = 0xA5A5_0007;
    const no_bus_master = pciCommandWithoutBusMaster(command);
    try std.testing.expectEqual(@as(u32, 0x0000_0003), no_bus_master);
    try std.testing.expectEqual(@as(u32, 0), no_bus_master & 0xFFFF_0000);

    const memory_only = pciCommandForMemoryOnly(0xA5A5_0405);
    try std.testing.expectEqual(@as(u32, 0x0000_0403), memory_only);
    try std.testing.expectEqual(@as(u32, 0), memory_only & (1 << 2));

    try std.testing.expectEqual(@as(u16, 0x2003), cplusCommandForRtl8168(0xFFFF));
    try std.testing.expectEqual(@as(u16, 0x0000), cplusCommandForRtl8168(0x0078));
    try std.testing.expectEqual(@as(u32, 0x2712_3456), rtl8168AspmEntryLatencyWriteValue(0xAB12_3456));
}

test "RTL8168H retained calibration transforms" {
    try std.testing.expectEqual(@as(u16, 0x060A), rtl8168h_eee_txidle);
    try std.testing.expectEqual(@as(u16, 0x9234), rtl8168hAdcBias(0x0080, 0x246C));
    try std.testing.expectEqual(@as(u16, 0x0000), rtl8168hRlenValue(0x0003));
    try std.testing.expectEqual(@as(u16, 0x5555), rtl8168hRlenValue(0x0008));
    try std.testing.expectEqual(@as(?u16, null), rtl8168hSawCounterValue(0));
    try std.testing.expectEqual(@as(?u16, 0x0400), rtl8168hSawCounterValue(15_625));
}

test "descriptor publication and receive validation" {
    const rx = rxOwnedOptions(2048, true);
    try std.testing.expect((rx & descriptor_owned) != 0);
    try std.testing.expect((rx & descriptor_end_of_ring) != 0);
    try std.testing.expectEqual(@as(u32, 2048), rx & descriptor_length_mask);

    const tx = txOwnedOptions(60, false);
    try std.testing.expect((tx & descriptor_owned) != 0);
    try std.testing.expect((tx & descriptor_first_segment) != 0);
    try std.testing.expect((tx & descriptor_last_segment) != 0);

    try std.testing.expectEqual(@as(?u32, 60), rxFrameLength(descriptor_first_segment | descriptor_last_segment | 64, 2048));
    try std.testing.expectEqual(@as(?u32, null), rxFrameLength(descriptor_owned | descriptor_first_segment | descriptor_last_segment | 64, 2048));
    try std.testing.expectEqual(@as(?u32, null), rxFrameLength(descriptor_first_segment | descriptor_last_segment | rx_error_summary | 64, 2048));
    try std.testing.expectEqual(@as(u64, 10), ticksForMilliseconds(1000, 10));
    try std.testing.expectEqual(@as(u64, 1), ticksForMilliseconds(100, 1));
}
