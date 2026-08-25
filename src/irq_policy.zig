pub const rx_ok: u16 = 0x0001;
pub const rx_error: u16 = 0x0002;
pub const tx_ok: u16 = 0x0004;
pub const tx_error: u16 = 0x0008;
pub const rx_overflow: u16 = 0x0010;
pub const link_change: u16 = 0x0020;
pub const rx_fifo_overflow: u16 = 0x0040;
pub const tx_desc_unavailable: u16 = 0x0080;
pub const system_error: u16 = 0x8000;

pub const rx_mask: u16 = rx_ok | rx_error | rx_overflow | rx_fifo_overflow;

pub fn needsRxTask(raw_isr: u16) bool {
    return (raw_isr & (rx_mask | system_error)) != 0;
}

test "RTL8168 TX and link causes do not publish RX work" {
    const std = @import("std");
    try std.testing.expect(!needsRxTask(tx_ok));
    try std.testing.expect(!needsRxTask(tx_error | tx_desc_unavailable));
    try std.testing.expect(!needsRxTask(link_change));
}

test "RTL8168 RX and recovery causes publish task work" {
    const std = @import("std");
    try std.testing.expect(needsRxTask(rx_ok));
    try std.testing.expect(needsRxTask(rx_fifo_overflow | tx_ok));
    try std.testing.expect(needsRxTask(system_error));
}
