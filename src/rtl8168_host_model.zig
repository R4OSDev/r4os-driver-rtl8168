// Deterministisches RTL8168GU-Hostmodell.
//
// Dieses Testmodul faehrt den ECHTEN Treibercode (main.zig) gegen ein
// Register-/DMA-Modell des realen Lenovo-Ziels (XID 0x509, RTL8168GU).
//
// Der Treiber bindet seit dem Rueckbau wieder ueber den bewaehrten
// reset-freien Legacy-Pfad des 0.59.5-Stands. Das Modell fixiert diesen
// Pfad in beide Richtungen:
//   positiv : Kaltbind bewegt Verkehr, exakte Legacy-Registerwerte,
//             MSI-Vorrang mit INTx-/Poll-Fallback, Kanarienvogel-Marker,
//             kalibrierte Recovery (SYSErr ja, PCSTimeout nein)
//   negativ : Der Bind macht KEINE indirekten Registerzugriffe (ERI, EPHY,
//             MAC-OCP, CFG9346) und KEINEN CmdReset. Jede Wiedereinfuehrung
//             bricht diese Tests und braucht einen realen Mehrboot-
//             Kaltstartnachweis.
// Das Warm-OOB-Wissen (Firmware haelt den Shared-FIFO nach Plattformreset,
// TX wird konsumiert, RX bleibt tot) bleibt als dokumentierte
// Plattformrealitaet modelliert; die Antwort darauf ist der Kaltstart und
// der Kernel-Transition-Shutdown, nicht ein Bind-Eingriff.

const std = @import("std");
const driver = @import("main.zig");
const contract = @import("rtl8168_contract.zig");
const r4os = @import("r4os");
const abi = r4os.abi;

// ---------------------------------------------------------------------------
// Registeroffsets (Spiegel der Treiberkonstanten)
// ---------------------------------------------------------------------------
const REG_MAC0: u64 = 0x00;
const REG_TX_DESC_LOW: u64 = 0x20;
const REG_TX_DESC_HIGH: u64 = 0x24;
const REG_CHIP_COMMAND: u64 = 0x37;
const REG_TX_POLL: u64 = 0x38;
const REG_INTERRUPT_MASK: u64 = 0x3C;
const REG_INTERRUPT_STATUS: u64 = 0x3E;
const REG_TX_CONFIG: u64 = 0x40;
const REG_RX_CONFIG: u64 = 0x44;
const REG_CFG9346: u64 = 0x50;
const REG_PHY_STATUS: u64 = 0x6C;
const REG_ERI_DATA: u64 = 0x70;
const REG_ERI_ACCESS: u64 = 0x74;
const REG_EPHY_ACCESS: u64 = 0x80;
const REG_MAC_OCP: u64 = 0xB0;
const REG_GPHY_OCP: u64 = 0xB8;
const REG_MCU: u64 = 0xD3;
const REG_RX_MAX_SIZE: u64 = 0xDA;
const REG_CPLUS_COMMAND: u64 = 0xE0;
const REG_RX_DESC_LOW: u64 = 0xE4;
const REG_RX_DESC_HIGH: u64 = 0xE8;
const REG_MAX_TX_PACKET_SIZE: u64 = 0xEC;
const REG_MISC: u64 = 0xF0;

const CHIP_COMMAND_RESET: u8 = 0x10;
const CHIP_COMMAND_RX_ENABLE: u8 = 0x08;
const CHIP_COMMAND_TX_ENABLE: u8 = 0x04;
const MCU_RXTX_EMPTY: u8 = (1 << 5) | (1 << 4);
const MCU_NOW_IS_OOB: u8 = 1 << 7;
const MCU_LINK_LIST_READY: u8 = 1 << 1;
const MISC_RXDV_GATED_ENABLE: u32 = 1 << 19;
const TX_CONFIG_FIFO_EMPTY: u32 = 1 << 11;
const PHY_STATUS_LINK: u8 = 1 << 1;
const RX_CONFIG_ACCEPT_BROADCAST: u32 = 1 << 3;
const RX_CONFIG_ACCEPT_MULTICAST: u32 = 1 << 2;
const RX_CONFIG_ACCEPT_PHYSICAL: u32 = 1 << 1;
const PCI_COMMAND_BUS_MASTER: u32 = 1 << 2;
const INTERRUPT_SYSTEM_ERROR: u16 = 0x8000;
const INTERRUPT_PCS_TIMEOUT: u16 = 0x4000;

// Erwartete Legacy-Registerwerte des reset-freien Binds.
const LEGACY_TX_CONFIG: u32 = (3 << 24) | (7 << 8);
const LEGACY_RX_CONFIG: u32 = (7 << 13) | (7 << 8) |
    RX_CONFIG_ACCEPT_BROADCAST | RX_CONFIG_ACCEPT_MULTICAST | RX_CONFIG_ACCEPT_PHYSICAL;

// XID 0x509 in den TX_CONFIG-Versionsbits (Maske 0xFCF << 20).
const TX_CONFIG_VERSION_BITS: u32 = 0x5090_0000;
const TX_CONFIG_VERSION_MASK: u32 = 0xFCF0_0000;

const MODEL_MAC = [6]u8{ 0x98, 0xFA, 0x9B, 0xF8, 0xDD, 0x5D };
const DMA_PHYS_BASE: u64 = 0x0100_0000;

// ---------------------------------------------------------------------------
// Modellzustand
// ---------------------------------------------------------------------------
const FifoOwner = enum { firmware, driver_mode };

const FwOption = enum { off, on, force };

const Scenario = struct {
    // Firmware haelt den Shared-FIFO nach Plattformreset (reales AA-Bild).
    warm_oob: bool = false,
    // Der reale GU besitzt eine MSI-Capability; false modelliert einen
    // Kernel ohne MSI-Slot beziehungsweise ein Geraet ohne Capability.
    msi_available: bool = true,
    // OPTION RTL8168 msi=off: Killswitch, der den Kernel-MSI-Slot nie anfasst.
    opt_msi_off: bool = false,
    // OPTION RTL8168 fw=on|force: optionaler Firmware-Ladepfad (0.59.22).
    opt_fw: FwOption = .off,
    // OPTION RTL8168 warmfix=on: Recovery-Eskalation (0.59.24). Der
    // Bridge-Check am Bind ist Standardverhalten und braucht keine Option.
    opt_warmfix: bool = false,
    // Reales 0.59.23-Warmbild: solange die Firmware den Shared-FIFO haelt,
    // holt die TX-Engine KEINE Deskriptoren ab (Stall statt AA-Schlucken).
    warm_stall: bool = false,
    // Neue Leithypothese aus Warmtest Runde 1: Der Root-Port ueber der NIC
    // verliert sein Bus-Master-Enable - MMIO geht, aber alle von der NIC
    // initiierten Upstream-Zugriffe (TX-Fetch, RX-Write, MSI) sterben.
    bridge_bme_off: bool = false,
    // Der PHY meldet den RAM-Code-Versionsmarker 0x801E bereits als aktuell.
    phy_ram_code_current: bool = false,
    // Kaltbind ohne Link: der einzige erlaubte indirekte Zugriff ist der
    // BMCR-Autoneg-Anstoss ueber GPHY-OCP.
    link_down: bool = false,
    // Modelliert das reale AC-Fehlerbild: die TX-Engine schliesst nie ab.
    tx_never_completes: bool = false,
};

const BlockReason = struct {
    oob: u32 = 0,
    rxdv_gated: u32 = 0,
    rx_disabled: u32 = 0,
    bus_master_off: u32 = 0,
    accept_filtered: u32 = 0,
    ring_full: u32 = 0,
};

const Model = struct {
    scenario: Scenario = .{},
    regs: [4096]u8 = .{0} ** 4096,
    pci_config: [4096]u8 = .{0} ** 4096,
    eri: [1024]u32 = .{0} ** 1024,
    ephy: [32]u16 = .{0} ** 32,
    mac_ocp: [32768]u16 = .{0} ** 32768,
    gphy_ocp: [32768]u16 = .{0} ** 32768,

    fifo_owner: FifoOwner = .driver_mode,
    phy_reset_seen: bool = false,
    now_is_oob_cleared: bool = false,
    e8de_bit14_cleared: bool = false,

    mac_ocp_readback: u32 = 0,
    gphy_readback: u32 = 0,
    eri_access_readback: u32 = 0,
    ephy_readback: u32 = 0,

    // Negative Konformitaet: der Bind darf diese Zaehler nicht erhoehen.
    reset_count: u32 = 0,
    eri_write_count: u32 = 0,
    ephy_write_count: u32 = 0,
    mac_ocp_write_count: u32 = 0,
    gphy_write_count: u32 = 0,
    cfg9346_unlocks: u32 = 0,
    free_dma_calls: u32 = 0,

    // Firmware-Vertragsspur (0.59.22): monotone MAC-OCP-Schreibsequenz
    // plus Ereignismarken fuer die Reihenfolgepruefung des MCU-Vertrags.
    mac_ocp_seq: u32 = 0,
    seq_bps_clear: u32 = 0,
    seq_fc26_zero: u32 = 0,
    seq_patch_start: u32 = 0,
    seq_fc26_enable: u32 = 0,
    seq_breakpoints_done: u32 = 0,
    // Indirekte PHY-Parameter (Adresslatch 0xA436, Daten 0xA438).
    phy_param_latch: u16 = 0,
    phy_params: [65536]u16 = .{0} ** 65536,
    // Parent-Root-Port (Bus 0): COMMAND-Register des Bridge-Geraets.
    bridge_command: u32 = 0x0006,

    tx_index: usize = 0,
    rx_index: usize = 0,
    wire_tx_frames: u32 = 0,
    oob_swallowed_tx: u32 = 0,
    blocked: BlockReason = .{},

    sim_ticks: u64 = 0,

    dma_phys: u64 = 0,
    dma_host: usize = 0,
    dma_bytes: u32 = 0,

    backend: ?*const abi.NetBackend = null,
    received_frames: u32 = 0,
    received_last_len: u32 = 0,
    irq_routes: [16]u8 = .{0xFF} ** 16,
    irq_route_count: usize = 0,
    msi_enable_calls: u32 = 0,

    log_buffer: [32768]u8 = .{0} ** 32768,
    log_len: usize = 0,

    recorded_rx_config: u32 = 0,
    recorded_tx_config: u32 = 0,
    recorded_rx_max: u16 = 0,
    recorded_max_tx_packet: u8 = 0,
};

var model: Model = .{};

fn resetModel(scenario: Scenario) void {
    model = .{};
    model.scenario = scenario;
    model.fifo_owner = if (scenario.warm_oob) .firmware else .driver_mode;

    // MMIO-Grundzustand: permanente MAC, Linkstatus, CPlusCmd normal_mode,
    // RXDV-Gate von der Firmware gesetzt (der Bind muss es loeschen).
    for (MODEL_MAC, 0..) |byte, index| model.regs[index] = byte;
    model.regs[REG_PHY_STATUS] = if (scenario.link_down) 0 else PHY_STATUS_LINK;
    model.regs[0xE0] = 0x00;
    model.regs[0xE1] = 0x20; // CPlusCmd bit13 (normal mode)
    rawWrite(REG_MISC, MISC_RXDV_GATED_ENABLE);

    // PHY: BMCR mit Autoneg-Enable an GPHY-OCP 0xA400.
    model.gphy_ocp[0xA400 / 2] = 0x1140;
    // Optional: RAM-Code-Versionsmarker meldet bereits den aktuellen Stand.
    if (scenario.phy_ram_code_current) model.phy_params[0x801E] = 0x0001;
    // Root-Port-COMMAND: im BME-off-Szenario nur Memory-Space aktiv.
    model.bridge_command = if (scenario.bridge_bme_off) 0x0002 else 0x0006;

    // PCI-Konfigraum: 10EC:8168, rev 0x10, Subsystem 17AA:38C7,
    // Status mit Capability-Liste, Kette PM(0x40) -> PCIe(0x50).
    writeConfig32(0x00, 0x8168_10EC);
    // Warm-retained: Firmware laesst Memory+IO+BusMaster aktiv zurueck.
    writeConfig32(0x04, 0x0010_0007);
    writeConfig32(0x08, 0x0200_0010);
    writeConfig32(0x2C, 0x38C7_17AA);
    writeConfig32(0x34, 0x0000_0040);
    writeConfig32(0x40, 0x0003_5001); // PM cap, next 0x50
    writeConfig32(0x44, 0x0000_0000); // PMCSR: D0
    writeConfig32(0x50, 0x0002_0010); // PCIe cap, next 0
    writeConfig32(0x60, 0x0000_0002); // Link Control: ASPM L1 aktiv
    // BARs: BAR0 IO, BAR1 leer, BAR2 64-Bit-Memory.
    writeConfig32(0x10, 0x0000_E001);
    writeConfig32(0x14, 0x0000_0000);
    writeConfig32(0x18, 0xFC00_0004);
    writeConfig32(0x1C, 0x0000_0000);
}

fn writeConfig32(offset: u16, value: u32) void {
    std.mem.writeInt(u32, model.pci_config[offset..][0..4], value, .little);
}

fn readConfig32(offset: u16) u32 {
    return std.mem.readInt(u32, model.pci_config[offset..][0..4], .little);
}

fn busMasterOn() bool {
    return (readConfig32(0x04) & PCI_COMMAND_BUS_MASTER) != 0;
}

fn upstreamDmaAlive() bool {
    // Der Root-Port muss Bus-Master-Enable tragen, sonst sterben alle von
    // der NIC initiierten Upstream-Zugriffe.
    return (model.bridge_command & PCI_COMMAND_BUS_MASTER) != 0;
}

fn translatePhys(phys: u64) ?[*]u8 {
    if (model.dma_host == 0) return null;
    if (phys < model.dma_phys or phys >= model.dma_phys + model.dma_bytes) return null;
    const base: [*]u8 = @ptrFromInt(model.dma_host);
    return base + (phys - model.dma_phys);
}

fn rawRead(offset: u64, comptime T: type) T {
    return std.mem.readInt(T, model.regs[@intCast(offset)..][0..@sizeOf(T)], .little);
}

fn rawWrite(offset: u64, value: anytype) void {
    const T = @TypeOf(value);
    std.mem.writeInt(T, model.regs[@intCast(offset)..][0..@sizeOf(T)], value, .little);
}

fn mcuValue() u8 {
    var value: u8 = MCU_RXTX_EMPTY;
    if (model.scenario.warm_oob and !model.now_is_oob_cleared) value |= MCU_NOW_IS_OOB;
    const ll_ready = model.fifo_owner == .driver_mode or
        (model.now_is_oob_cleared and model.e8de_bit14_cleared);
    if (ll_ready) value |= MCU_LINK_LIST_READY;
    return value;
}

fn applyChipCommandWrite(value: u8) void {
    if ((value & CHIP_COMMAND_RESET) != 0) {
        model.reset_count += 1;
        // CmdReset: RX/TX-Engines stoppen, RESET liest sich sofort geloescht.
        // Der FIFO-Besitz wechselt durch einen MAC-Reset NICHT.
        rawWrite(REG_CHIP_COMMAND, value & ~(CHIP_COMMAND_RESET |
            CHIP_COMMAND_RX_ENABLE | CHIP_COMMAND_TX_ENABLE));
        return;
    }
    rawWrite(REG_CHIP_COMMAND, value);
}

fn applyMacOcpCommand(command: u32) void {
    const register: u16 = @truncate((command >> 16) << 1);
    const value: u16 = @truncate(command & 0xFFFF);
    if ((command & (1 << 31)) != 0) {
        model.mac_ocp[register / 2] = value;
        model.mac_ocp_write_count += 1;
        model.mac_ocp_seq += 1;
        // Ownership-Maschine: E8DE-Link-List-Uebergabe (rtl_hw_init_8168g).
        if (register == 0xE8DE) {
            if ((value & (1 << 14)) == 0) model.e8de_bit14_cleared = true;
            if ((value & (1 << 15)) != 0 and model.now_is_oob_cleared) {
                model.fifo_owner = .driver_mode;
            }
        }
        // Vertragsspur des MCU-Ladepfads.
        if (register == 0xFC36 and value == 0x0000 and model.seq_bps_clear == 0) {
            model.seq_bps_clear = model.mac_ocp_seq;
        }
        if (register == 0xFC26 and value == 0x0000 and model.seq_fc26_zero == 0) {
            model.seq_fc26_zero = model.mac_ocp_seq;
        }
        if (register == 0xF800 and model.seq_patch_start == 0) {
            model.seq_patch_start = model.mac_ocp_seq;
        }
        if (register == 0xFC26 and value == 0x8000) {
            model.seq_fc26_enable = model.mac_ocp_seq;
        }
        if (register == 0xFC36 and value == 0x08DF) {
            model.seq_breakpoints_done = model.mac_ocp_seq;
        }
    } else {
        model.mac_ocp_readback = model.mac_ocp[register / 2];
    }
}

fn applyGphyOcpCommand(command: u32) void {
    const address: u16 = @truncate((command >> 16) << 1);
    const value: u16 = @truncate(command & 0xFFFF);
    if ((command & (1 << 31)) != 0) {
        var stored = value;
        if (address == 0xA400) {
            // BMCR: Reset- und Restart-Autoneg-Bits setzen sich selbst zurueck.
            if ((value & (1 << 15)) != 0) model.phy_reset_seen = true;
            stored &= ~@as(u16, (1 << 15) | (1 << 9));
        }
        model.gphy_ocp[address / 2] = stored;
        // Indirekter PHY-Parameterzugriff (Seite 0x0A43: 0x13/0x14).
        if (address == 0xA436) {
            model.phy_param_latch = value;
        } else if (address == 0xA438) {
            model.phy_params[model.phy_param_latch] = value;
        }
        model.gphy_write_count += 1;
        model.gphy_readback = 0; // Flag geloescht = Write abgeschlossen.
    } else {
        // Spezialfaelle vor dem flachen Registerbild: Parameterdaten und
        // der Patch-Request-Status (Seite 0x0B80 Reg 0x10 Bit 6 folgt dem
        // Requestbit Seite 0x0B82 Reg 0x10 Bit 4).
        const readback: u16 = if (address == 0xA438)
            model.phy_params[model.phy_param_latch]
        else if (address == 0xB800)
            (if ((model.gphy_ocp[0xB820 / 2] & (1 << 4)) != 0) @as(u16, 1 << 6) else 0)
        else
            model.gphy_ocp[address / 2];
        model.gphy_readback = (@as(u32, 1) << 31) | @as(u32, readback);
    }
}

fn applyEriCommand(command: u32) void {
    const address: u16 = @truncate(command & 0xFFF);
    const byte_enable: u4 = @truncate((command >> 12) & 0xF);
    if ((command & (1 << 31)) != 0) {
        const data = rawRead(REG_ERI_DATA, u32);
        var current = model.eri[address / 4];
        var lane: u5 = 0;
        while (lane < 4) : (lane += 1) {
            if ((byte_enable & (@as(u4, 1) << @intCast(lane))) != 0) {
                const mask = @as(u32, 0xFF) << (8 * lane);
                current = (current & ~mask) | (data & mask);
            }
        }
        model.eri[address / 4] = current;
        model.eri_write_count += 1;
        model.eri_access_readback = command & ~(@as(u32, 1) << 31);
    } else {
        rawWrite(REG_ERI_DATA, model.eri[address / 4]);
        model.eri_access_readback = command | (@as(u32, 1) << 31);
    }
}

fn applyEphyCommand(command: u32) void {
    const register: u5 = @truncate((command >> 16) & 0x1F);
    if ((command & (1 << 31)) != 0) {
        model.ephy[register] = @truncate(command & 0xFFFF);
        model.ephy_write_count += 1;
        model.ephy_readback = command & ~(@as(u32, 1) << 31);
    } else {
        model.ephy_readback = (@as(u32, 1) << 31) | model.ephy[register];
    }
}

fn consumeTxRing() void {
    if (model.scenario.tx_never_completes) return;
    // Reales 0.59.23-Warmbild: im Firmware-/OOB-Besitz holt die TX-Engine
    // keine Deskriptoren ab - sie bleiben owned und stallen.
    if (model.scenario.warm_stall and model.fifo_owner != .driver_mode) return;
    // Root-Port ohne BME: Deskriptor-Fetch (Upstream-Read) stirbt.
    if (!upstreamDmaAlive()) return;
    const chip = rawRead(REG_CHIP_COMMAND, u8);
    if ((chip & CHIP_COMMAND_TX_ENABLE) == 0) return;
    if (!busMasterOn()) return;
    const ring_phys = (@as(u64, rawRead(REG_TX_DESC_HIGH, u32)) << 32) |
        rawRead(REG_TX_DESC_LOW, u32);
    const ring = translatePhys(ring_phys) orelse return;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        const descriptor: *contract.Descriptor =
            @ptrCast(@alignCast(ring + model.tx_index * @sizeOf(contract.Descriptor)));
        if ((descriptor.opts1 & contract.descriptor_owned) == 0) return;
        if (model.fifo_owner == .driver_mode) {
            model.wire_tx_frames += 1;
        } else {
            // Reales AA-Fehlerbild: OOB-Firmware konsumiert TX-Deskriptoren,
            // ohne dass die Frames den Draht erreichen muessen.
            model.oob_swallowed_tx += 1;
        }
        const end_of_ring = (descriptor.opts1 & contract.descriptor_end_of_ring) != 0;
        descriptor.opts1 &= ~contract.descriptor_owned;
        model.tx_index = if (end_of_ring) 0 else model.tx_index + 1;
    }
}

/// Liefert einen Frame in den RX-Ring, wenn der modellierte Hardwarezustand
/// das real zulassen wuerde. Blockgruende werden gezaehlt.
pub fn deliverFrame(frame: []const u8) bool {
    if (model.fifo_owner != .driver_mode) {
        model.blocked.oob += 1;
        return false;
    }
    if ((rawRead(REG_MISC, u32) & MISC_RXDV_GATED_ENABLE) != 0) {
        model.blocked.rxdv_gated += 1;
        return false;
    }
    const chip = rawRead(REG_CHIP_COMMAND, u8);
    if ((chip & CHIP_COMMAND_RX_ENABLE) == 0) {
        model.blocked.rx_disabled += 1;
        return false;
    }
    if (!busMasterOn()) {
        model.blocked.bus_master_off += 1;
        return false;
    }
    if (!upstreamDmaAlive()) {
        model.blocked.bus_master_off += 1;
        return false;
    }
    const rx_config = rawRead(REG_RX_CONFIG, u32);
    if ((rx_config & (RX_CONFIG_ACCEPT_BROADCAST | RX_CONFIG_ACCEPT_PHYSICAL)) == 0) {
        model.blocked.accept_filtered += 1;
        return false;
    }
    const ring_phys = (@as(u64, rawRead(REG_RX_DESC_HIGH, u32)) << 32) |
        rawRead(REG_RX_DESC_LOW, u32);
    const ring = translatePhys(ring_phys) orelse {
        model.blocked.ring_full += 1;
        return false;
    };
    const descriptor: *contract.Descriptor =
        @ptrCast(@alignCast(ring + model.rx_index * @sizeOf(contract.Descriptor)));
    if ((descriptor.opts1 & contract.descriptor_owned) == 0) {
        model.blocked.ring_full += 1;
        return false;
    }
    const buffer = translatePhys(descriptor.addr) orelse {
        model.blocked.ring_full += 1;
        return false;
    };
    for (frame, 0..) |byte, index| buffer[index] = byte;
    const end_of_ring = (descriptor.opts1 & contract.descriptor_end_of_ring) != 0;
    const wire_len: u32 = @intCast(frame.len + 4); // Hardware meldet inkl. FCS.
    descriptor.opts1 = wire_len |
        contract.descriptor_first_segment |
        contract.descriptor_last_segment |
        (if (end_of_ring) contract.descriptor_end_of_ring else 0);
    model.rx_index = if (end_of_ring) 0 else model.rx_index + 1;
    return true;
}

// ---------------------------------------------------------------------------
// MMIO-Hooks (Testseam aus main.zig)
// ---------------------------------------------------------------------------
fn hookRead8(offset: u64) u8 {
    return switch (offset) {
        REG_MCU => mcuValue(),
        else => rawRead(offset, u8),
    };
}

fn hookRead16(offset: u64) u16 {
    return rawRead(offset, u16);
}

fn hookRead32(offset: u64) u32 {
    return switch (offset) {
        REG_TX_CONFIG => (rawRead(REG_TX_CONFIG, u32) & ~TX_CONFIG_VERSION_MASK) |
            TX_CONFIG_VERSION_BITS | TX_CONFIG_FIFO_EMPTY,
        REG_MAC_OCP => model.mac_ocp_readback,
        REG_GPHY_OCP => model.gphy_readback,
        REG_ERI_ACCESS => model.eri_access_readback,
        REG_EPHY_ACCESS => model.ephy_readback,
        else => rawRead(offset, u32),
    };
}

fn hookWrite8(offset: u64, value: u8) void {
    switch (offset) {
        REG_CHIP_COMMAND => applyChipCommandWrite(value),
        REG_TX_POLL => {
            rawWrite(offset, value);
            consumeTxRing();
        },
        REG_CFG9346 => {
            if (value == 0xC0) model.cfg9346_unlocks += 1;
            rawWrite(offset, value);
        },
        REG_MCU => {
            if ((value & MCU_NOW_IS_OOB) == 0 and model.scenario.warm_oob) {
                model.now_is_oob_cleared = true;
            }
            rawWrite(offset, value);
        },
        REG_MAX_TX_PACKET_SIZE => {
            model.recorded_max_tx_packet = value;
            rawWrite(offset, value);
        },
        else => rawWrite(offset, value),
    }
}

fn hookWrite16(offset: u64, value: u16) void {
    switch (offset) {
        REG_INTERRUPT_STATUS => {
            // W1C-Semantik.
            const pending = rawRead(REG_INTERRUPT_STATUS, u16);
            rawWrite(REG_INTERRUPT_STATUS, pending & ~value);
        },
        REG_RX_MAX_SIZE => {
            model.recorded_rx_max = value;
            rawWrite(offset, value);
        },
        else => rawWrite(offset, value),
    }
}

fn hookWrite32(offset: u64, value: u32) void {
    switch (offset) {
        REG_MAC_OCP => applyMacOcpCommand(value),
        REG_GPHY_OCP => applyGphyOcpCommand(value),
        REG_ERI_ACCESS => applyEriCommand(value),
        REG_EPHY_ACCESS => applyEphyCommand(value),
        REG_RX_CONFIG => {
            model.recorded_rx_config = value;
            rawWrite(offset, value);
        },
        REG_TX_CONFIG => {
            model.recorded_tx_config = value;
            rawWrite(offset, value);
        },
        else => rawWrite(offset, value),
    }
}

const mmio_hooks = driver.TestMmioHooks{
    .read8 = hookRead8,
    .read16 = hookRead16,
    .read32 = hookRead32,
    .write8 = hookWrite8,
    .write16 = hookWrite16,
    .write32 = hookWrite32,
};

// ---------------------------------------------------------------------------
// DriverApi-Mock
// ---------------------------------------------------------------------------
fn appendLog(text: [*:0]const u8) void {
    const span = std.mem.span(text);
    if (model.log_len + span.len + 1 >= model.log_buffer.len) return;
    @memcpy(model.log_buffer[model.log_len..][0..span.len], span);
    model.log_len += span.len;
    model.log_buffer[model.log_len] = '\n';
    model.log_len += 1;
}

fn logContains(needle: []const u8) bool {
    return std.mem.indexOf(u8, model.log_buffer[0..model.log_len], needle) != null;
}

fn mockLogInfo(text: [*:0]const u8) callconv(.c) void {
    appendLog(text);
}
fn mockLogWarn(text: [*:0]const u8) callconv(.c) void {
    appendLog(text);
}
fn mockLogError(text: [*:0]const u8) callconv(.c) void {
    appendLog(text);
}

fn mockPortInb(_: u16) callconv(.c) u8 {
    return 0;
}
fn mockPortOutb(_: u16, _: u8) callconv(.c) void {}
fn mockPortInw(_: u16) callconv(.c) u16 {
    return 0;
}
fn mockPortOutw(_: u16, _: u16) callconv(.c) void {}
fn mockPortInl(_: u16) callconv(.c) u32 {
    return 0;
}
fn mockPortOutl(_: u16, _: u32) callconv(.c) void {}

fn mockAllocDmaBuffer(_: u32, _: u32) callconv(.c) u64 {
    return 0;
}
fn mockFreeDmaBuffer(_: u64, _: u32) callconv(.c) void {}
fn mockRequestIrq(_: u8, _: *const anyopaque) callconv(.c) i32 {
    return -1;
}
fn mockReleaseIrq(_: u8) callconv(.c) i32 {
    return -1;
}

const empty_option: [:0]const u8 = "";
const off_option: [:0]const u8 = "off";
const on_option: [:0]const u8 = "on";
const force_option: [:0]const u8 = "force";
fn mockGetOption(_: [*:0]const u8, key: [*:0]const u8) callconv(.c) [*:0]const u8 {
    const wanted = std.mem.span(key);
    if (std.mem.eql(u8, wanted, "msi") and model.scenario.opt_msi_off) return off_option.ptr;
    if (std.mem.eql(u8, wanted, "fw")) {
        return switch (model.scenario.opt_fw) {
            .off => empty_option.ptr,
            .on => on_option.ptr,
            .force => force_option.ptr,
        };
    }
    if (std.mem.eql(u8, wanted, "warmfix") and model.scenario.opt_warmfix) return on_option.ptr;
    return empty_option.ptr;
}

fn mockRegisterStub(_: [*:0]const u8, _: *const anyopaque) callconv(.c) i32 {
    return -1;
}
fn mockUnregisterStub(_: [*:0]const u8) callconv(.c) i32 {
    return -1;
}

fn mockRegisterNetBackend(_: [*:0]const u8, backend: *const anyopaque) callconv(.c) i32 {
    model.backend = @ptrCast(@alignCast(backend));
    return 0;
}

var dma_backing: [262144]u8 align(4096) = undefined;

fn mockAllocDmaRegion(bytes: u32, alignment: u32, out: *abi.DmaBuffer) callconv(.c) i32 {
    _ = alignment;
    if (bytes > dma_backing.len) return -1;
    @memset(dma_backing[0..bytes], 0);
    model.dma_phys = DMA_PHYS_BASE;
    model.dma_host = @intFromPtr(&dma_backing);
    model.dma_bytes = bytes;
    out.* = .{
        .phys_addr = DMA_PHYS_BASE,
        .virt_addr = @intFromPtr(&dma_backing),
        .bytes = bytes,
        .alignment = 4096,
    };
    return 0;
}

fn mockFreeDmaRegion(buffer: *abi.DmaBuffer) callconv(.c) void {
    model.free_dma_calls += 1;
    buffer.* = .{};
}

fn mockPciDeviceCount() callconv(.c) u32 {
    return 2;
}

fn mockPciDeviceAt(index: u32, out: *abi.PciDeviceInfo) callconv(.c) i32 {
    if (index == 0) {
        out.* = .{
            .bus_kind = 1,
            .bus = 2,
            .device = 0,
            .function = 0,
            .vendor_id = 0x10EC,
            .device_id = 0x8168,
            .class_code = 0x02,
            .subclass = 0x00,
            .interrupt_line = 10,
            .interrupt_pin = 1,
        };
        return 0;
    }
    if (index == 1) {
        // Parent-Root-Port auf Bus 0, Secondary/Subordinate = 2.
        out.* = .{
            .bus_kind = 1,
            .bus = 0,
            .device = 0x1C,
            .function = 0,
            .vendor_id = 0x8086,
            .device_id = 0x9D10,
            .class_code = 0x06,
            .subclass = 0x04,
            .interrupt_line = 0xFF,
            .interrupt_pin = 0,
        };
        return 0;
    }
    return -1;
}

fn mockPciFindByClass(_: u8, _: u8, _: u32, _: *abi.PciDeviceInfo) callconv(.c) i32 {
    return -1;
}

fn mockPciReadConfig32(_: u8, bus: u8, _: u8, _: u8, offset: u16) callconv(.c) u32 {
    if (bus == 0) {
        // Root-Port: COMMAND, Busnummern (Primary 0, Secondary 2, Sub 2).
        return switch (offset) {
            0x04 => model.bridge_command,
            0x18 => 0x0002_0200,
            else => 0,
        };
    }
    if (offset >= model.pci_config.len - 3) return 0xFFFF_FFFF;
    return readConfig32(offset);
}

fn mockPciWriteConfig32(_: u8, bus: u8, _: u8, _: u8, offset: u16, value: u32) callconv(.c) i32 {
    if (bus == 0) {
        if (offset == 0x04) model.bridge_command = value & 0xFFFF;
        return 0;
    }
    if (offset >= model.pci_config.len - 3) return -1;
    writeConfig32(offset, value);
    return 0;
}

fn mockPciReadBar(_: u8, _: u8, _: u8, _: u8, index: u8) callconv(.c) u32 {
    return switch (index) {
        0 => readConfig32(0x10),
        1 => readConfig32(0x14),
        2 => readConfig32(0x18),
        3 => readConfig32(0x1C),
        else => 0,
    };
}

fn mockPciEnableBusMaster(_: u8, _: u8, _: u8, _: u8, flags: u32) callconv(.c) i32 {
    var command = readConfig32(0x04) & 0x0000_FFFF;
    command |= PCI_COMMAND_BUS_MASTER;
    if ((flags & abi.pci_enable_memory_space) != 0) command |= 0x0002;
    writeConfig32(0x04, (readConfig32(0x04) & 0xFFFF_0000) | command);
    return 0;
}

fn mockPciEnableMsi(_: u8, _: u8, _: u8, _: u8) callconv(.c) i32 {
    model.msi_enable_calls += 1;
    if (!model.scenario.msi_available) return -2;
    return 28;
}

fn mockIrqRegister(irq: u8, _: abi.IrqHandler, _: usize, _: u32) callconv(.c) i32 {
    if (model.irq_route_count < model.irq_routes.len) {
        model.irq_routes[model.irq_route_count] = irq;
        model.irq_route_count += 1;
    }
    return 0;
}

fn mockIrqUnregister(_: u8, _: abi.IrqHandler, _: usize) callconv(.c) i32 {
    return 0;
}

fn mockIrqStats(_: u8, out: *abi.IrqStats) callconv(.c) i32 {
    out.* = .{};
    return 0;
}

fn mockPciMapBar(_: u8, _: u8, _: u8, _: u8, index: u8, bytes: u32, _: u32, out: *abi.MmioRegion) callconv(.c) i32 {
    if (index != 2) return -1;
    out.* = .{
        .phys_addr = 0xFC00_0000,
        .virt_addr = @intFromPtr(&model.regs),
        .bytes = bytes,
        .mapped_bytes = bytes,
        .bar_index = index,
    };
    return 0;
}

fn mockNetReceiveFrame(_: i32, _: [*]const u8, len: u32) callconv(.c) i32 {
    model.received_frames += 1;
    model.received_last_len = len;
    return 0;
}

fn mockTickCount() callconv(.c) u64 {
    return model.sim_ticks;
}

fn mockTimerFrequency() callconv(.c) u32 {
    return 1000;
}

fn mockWaitTicks(ticks: u64) callconv(.c) void {
    model.sim_ticks +%= @max(ticks, 1);
}

fn mockWorkSubmit(_: abi.DriverWorkHandler, _: usize, _: u32, _: *u32) callconv(.c) i32 {
    return -1;
}
fn mockWorkCancel(_: u32) callconv(.c) i32 {
    return -1;
}
fn mockCompletionWait(_: u32, _: u64, _: *i32) callconv(.c) i32 {
    return -1;
}
fn mockCompletionStatus(_: u32, _: *abi.DriverCompletionStatus) callconv(.c) i32 {
    return -1;
}
fn mockCompletionRelease(_: u32) callconv(.c) i32 {
    return -1;
}
fn mockWorkSummary(_: *abi.DriverWorkSummary) callconv(.c) i32 {
    return -1;
}
fn mockRegisterSynthEngineV2(_: [*:0]const u8, _: *const abi.SynthEngine) callconv(.c) i32 {
    return -1;
}
fn mockRegisterUsbHost(_: [*:0]const u8, _: *const abi.UsbHostController) callconv(.c) i32 {
    return -1;
}
fn mockStorageRecoveryBegin(_: [*:0]const u8) callconv(.c) i32 {
    return -1;
}
fn mockStorageRecoveryFinish(_: [*:0]const u8, _: i32) callconv(.c) i32 {
    return -1;
}

const mock_api = abi.DriverApi{
    .magic = abi.driver_magic,
    .version = abi.driver_api_version,
    .size = @sizeOf(abi.DriverApi),
    .reserved = 0,
    .log_info = mockLogInfo,
    .log_warn = mockLogWarn,
    .log_error = mockLogError,
    .port_inb = mockPortInb,
    .port_outb = mockPortOutb,
    .alloc_dma_buffer = mockAllocDmaBuffer,
    .free_dma_buffer = mockFreeDmaBuffer,
    .request_irq = mockRequestIrq,
    .release_irq = mockReleaseIrq,
    .get_option = mockGetOption,
    .register_audio_backend = mockRegisterStub,
    .register_storage_backend = mockRegisterStub,
    .register_input_backend = mockRegisterStub,
    .register_synth_engine = mockRegisterStub,
    .register_mixer_backend = mockRegisterStub,
    .register_net_backend = mockRegisterNetBackend,
    .alloc_dma_region = mockAllocDmaRegion,
    .free_dma_region = mockFreeDmaRegion,
    .pci_device_count = mockPciDeviceCount,
    .pci_device_at = mockPciDeviceAt,
    .pci_find_by_class = mockPciFindByClass,
    .pci_read_config32 = mockPciReadConfig32,
    .pci_write_config32 = mockPciWriteConfig32,
    .pci_read_bar = mockPciReadBar,
    .pci_enable_bus_master = mockPciEnableBusMaster,
    .irq_register = mockIrqRegister,
    .irq_unregister = mockIrqUnregister,
    .irq_stats = mockIrqStats,
    .pci_map_bar = mockPciMapBar,
    .port_inw = mockPortInw,
    .port_outw = mockPortOutw,
    .port_inl = mockPortInl,
    .port_outl = mockPortOutl,
    .net_receive_frame = mockNetReceiveFrame,
    .register_audio_output_backend = mockRegisterStub,
    .unregister_audio_backend = mockUnregisterStub,
    .tick_count = mockTickCount,
    .timer_frequency = mockTimerFrequency,
    .wait_ticks = mockWaitTicks,
    .register_synth_engine_v2 = mockRegisterSynthEngineV2,
    .unregister_storage_backend = mockUnregisterStub,
    .storage_backend_recovery_begin = mockStorageRecoveryBegin,
    .storage_backend_recovery_finish = mockStorageRecoveryFinish,
    .register_usb_host_controller = mockRegisterUsbHost,
    .unregister_usb_host_controller = mockUnregisterStub,
    .driver_work_submit = mockWorkSubmit,
    .driver_work_cancel = mockWorkCancel,
    .driver_completion_wait = mockCompletionWait,
    .driver_completion_status = mockCompletionStatus,
    .driver_completion_release = mockCompletionRelease,
    .driver_work_summary = mockWorkSummary,
    .pci_enable_msi = mockPciEnableMsi,
};

// ---------------------------------------------------------------------------
// Testhelfer
// ---------------------------------------------------------------------------
fn bindDriver(scenario: Scenario) i32 {
    resetModel(scenario);
    driver.test_mmio_hooks = &mmio_hooks;
    return driver.rtl8168_init(&mock_api);
}

fn pollBackend() void {
    const backend = model.backend orelse return;
    backend.poll.?(backend.context);
}

const test_frame = [_]u8{
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
    0x08, 0x06,
} ++ [_]u8{0xAB} ** 50;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cold bind uses the reset-free legacy path and moves traffic" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{}));
    try std.testing.expect(logContains("RTL8168.R4D xid=0x509 phy=gphy-ocp bind=reset-free"));
    try std.testing.expect(model.backend != null);
    // Kein CmdReset im gesamten Bind.
    try std.testing.expectEqual(@as(u32, 0), model.reset_count);
    // Das firmwareseitig gesetzte RXDV-Gate ist geloescht.
    try std.testing.expectEqual(@as(u32, 0), rawRead(REG_MISC, u32) & MISC_RXDV_GATED_ENABLE);
    // Der Bridge-Check ist Standardverhalten: Beweiszeile immer, auf einer
    // gesunden Bridge ohne Reparaturpfeil.
    try std.testing.expect(logContains("RTL8168.R4D warmfix pci endpoint=0x"));
    try std.testing.expect(logContains(" bridge=0x0006"));
    try std.testing.expect(!logContains(" -> 0x"));

    try std.testing.expect(deliverFrame(&test_frame));
    pollBackend();
    try std.testing.expectEqual(@as(u32, 1), model.received_frames);
    try std.testing.expectEqual(@as(u32, test_frame.len), model.received_last_len);
    try std.testing.expect(logContains("RTL8168.R4D rx path confirmed"));

    // TX ueber den echten Backend-Eintrag: Frame landet auf dem Draht.
    const backend = model.backend.?;
    const rc = backend.transmit.?(backend.context, &test_frame, test_frame.len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(u32, 1), model.wire_tx_frames);
}

test "cold bind performs no indirect register access (negative conformance)" {
    // Die Kernaussage des Rueckbaus: Der Bind fasst ERI, EPHY, MAC-OCP,
    // GPHY (bei Link up) und CFG9346 nicht an. Jede Wiedereinfuehrung
    // bricht diesen Test und braucht einen realen Kaltstartnachweis.
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{}));
    try std.testing.expectEqual(@as(u32, 0), model.eri_write_count);
    try std.testing.expectEqual(@as(u32, 0), model.ephy_write_count);
    try std.testing.expectEqual(@as(u32, 0), model.mac_ocp_write_count);
    try std.testing.expectEqual(@as(u32, 0), model.gphy_write_count);
    try std.testing.expectEqual(@as(u32, 0), model.cfg9346_unlocks);
    try std.testing.expect(!model.now_is_oob_cleared);
    try std.testing.expect(!model.phy_reset_seen);
}

test "cold bind with link down nudges autoneg through gphy-ocp only" {
    // Der einzige erlaubte indirekte Zugriff des Legacy-Binds: BMCR-Autoneg
    // anfordern, wenn kein Link anliegt. Kein Softreset, nichts weiter.
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .link_down = true }));
    try std.testing.expectEqual(@as(u32, 1), model.gphy_write_count);
    try std.testing.expect(!model.phy_reset_seen);
    try std.testing.expectEqual(@as(u16, 0x1140), model.gphy_ocp[0xA400 / 2]);
    try std.testing.expectEqual(@as(u32, 0), model.eri_write_count);
    try std.testing.expectEqual(@as(u32, 0), model.ephy_write_count);
    try std.testing.expectEqual(@as(u32, 0), model.mac_ocp_write_count);
}

test "cold bind register conformance matches the proven legacy values" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{}));
    try std.testing.expectEqual(LEGACY_TX_CONFIG, model.recorded_tx_config);
    try std.testing.expectEqual(LEGACY_RX_CONFIG, model.recorded_rx_config);
    try std.testing.expectEqual(@as(u8, 0x3F), model.recorded_max_tx_packet);
    try std.testing.expectEqual(@as(u16, 1522), model.recorded_rx_max);
    // CPlusCmd: normal_mode erhalten, VLAN/Checksum geloescht, DAC+MulRW an.
    try std.testing.expectEqual(@as(u16, 0x2018), rawRead(REG_CPLUS_COMMAND, u16));
}

test "bind prefers MSI and registers exactly the granted route" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{}));
    try std.testing.expectEqual(@as(u32, 1), model.msi_enable_calls);
    try std.testing.expectEqual(@as(usize, 1), model.irq_route_count);
    try std.testing.expectEqual(@as(u8, 28), model.irq_routes[0]);
    try std.testing.expect(logContains("RTL8168.R4D MSI registered"));

    // Recovery-Telemetrie: keine Vollresets im normalen Betrieb.
    try std.testing.expect(!logContains("RTL8168.R4D recovery cause="));
}

test "bind falls back to shared INTx when MSI is unavailable" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .msi_available = false }));
    try std.testing.expect(logContains("RTL8168.R4D MSI unavailable; trying shared INTx"));
    try std.testing.expect(logContains("RTL8168.R4D shared INTx registered"));
    // Line 10 plus GSIs 16..23.
    try std.testing.expectEqual(@as(usize, 9), model.irq_route_count);
    try std.testing.expectEqual(@as(u8, 10), model.irq_routes[0]);
    try std.testing.expectEqual(@as(u8, 16), model.irq_routes[1]);

    try std.testing.expect(deliverFrame(&test_frame));
    pollBackend();
    try std.testing.expectEqual(@as(u32, 1), model.received_frames);
}

test "msi=off option keeps the kernel MSI slot untouched" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .opt_msi_off = true }));
    try std.testing.expectEqual(@as(u32, 0), model.msi_enable_calls);
    try std.testing.expect(logContains("options msi=off irq=on"));
    try std.testing.expect(logContains("RTL8168.R4D shared INTx registered"));
}

test "canary probes autonomously and confirms the tx path" {
    // KEIN externer Verkehr, nur Polls mit fortschreitender Zeit: Der
    // Kanarienvogel muss den Sendepfad selbst beweisen und sich danach
    // abschalten.
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{}));
    var round: usize = 0;
    while (round < 6) : (round += 1) {
        model.sim_ticks +%= 2501;
        pollBackend();
    }
    try std.testing.expect(logContains("RTL8168.R4D tx canary confirmed"));
    try std.testing.expect(model.wire_tx_frames > 0);
    const frames_at_confirm = model.wire_tx_frames;
    // Nach der Bestaetigung sendet der Kanarienvogel nicht weiter.
    round = 0;
    while (round < 6) : (round += 1) {
        model.sim_ticks +%= 2501;
        pollBackend();
    }
    try std.testing.expectEqual(frames_at_confirm, model.wire_tx_frames);
}

test "tx stall recovery is bounded and reports cause telemetry" {
    // Reales Fehlerbild: die TX-Engine schliesst nie ab. Die Recovery muss
    // genau dann greifen, ihre Ursache dokumentieren und die Engine wieder
    // in einen sendefaehigen Zustand bringen - ohne Eskalationsleiter.
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .tx_never_completes = true }));
    const backend = model.backend.?;
    _ = backend.transmit.?(backend.context, &test_frame, test_frame.len);
    model.sim_ticks +%= 5001;
    pollBackend();
    try std.testing.expect(logContains("RTL8168.R4D recovery cause=tx-stall stall=1"));
    try std.testing.expect(model.reset_count > 0);
    try std.testing.expect(!logContains("bisect"));
    const chip = rawRead(REG_CHIP_COMMAND, u8);
    try std.testing.expectEqual(
        CHIP_COMMAND_RX_ENABLE | CHIP_COMMAND_TX_ENABLE,
        chip & (CHIP_COMMAND_RX_ENABLE | CHIP_COMMAND_TX_ENABLE),
    );
}

test "syserr triggers recovery while pcs timeout is only counted" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{}));
    // PCSTimeout: zaehlen, quittieren, KEIN Reset.
    rawWrite(REG_INTERRUPT_STATUS, INTERRUPT_PCS_TIMEOUT);
    pollBackend();
    try std.testing.expect(!logContains("RTL8168.R4D recovery cause="));
    try std.testing.expectEqual(@as(u16, 0), rawRead(REG_INTERRUPT_STATUS, u16));
    // SYSErr: einziger interruptgetriebener Recovery-Ausloeser.
    rawWrite(REG_INTERRUPT_STATUS, INTERRUPT_SYSTEM_ERROR);
    pollBackend();
    try std.testing.expect(logContains("RTL8168.R4D recovery cause=syserr"));
    try std.testing.expect(logContains("pcs=1"));
}

test "warm firmware-owned FIFO stays dead under the reset-free bind (documented reality)" {
    // Dokumentierte Plattformrealitaet, KEIN Treiberfehler: Haelt die
    // OOB-Firmware nach einem Plattformreset den Shared-FIFO, konsumiert
    // sie TX-Deskriptoren und RX erreicht den Ring nicht (reales AA-Bild).
    // Die Antwort ist der Kernel-Transition-Shutdown vor dem Reset plus
    // Kaltstart - nicht ein Bind-Eingriff, der den Kaltpfad riskiert.
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .warm_oob = true }));
    try std.testing.expect(model.fifo_owner == .firmware);

    try std.testing.expect(!deliverFrame(&test_frame));
    try std.testing.expect(model.blocked.oob > 0);
    const backend = model.backend.?;
    _ = backend.transmit.?(backend.context, &test_frame, test_frame.len);
    try std.testing.expectEqual(@as(u32, 1), model.oob_swallowed_tx);
    try std.testing.expectEqual(@as(u32, 0), model.wire_tx_frames);
}

test "fw=on loads the complete mac-mcu contract in vendor order" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .opt_fw = .on }));
    try std.testing.expect(logContains("options msi=on irq=on fw=on"));
    try std.testing.expect(logContains("RTL8168.R4D fw mac-mcu loaded words=417"));
    // Vertragsreihenfolge: BPS-Clear -> 0xFC26=0 -> Patchstart 0xF800 ->
    // Aktivierung 0xFC26=0x8000 -> Breakpoint-Abschluss 0xFC36=0x08DF.
    try std.testing.expect(model.seq_bps_clear > 0);
    try std.testing.expect(model.seq_bps_clear < model.seq_fc26_zero);
    try std.testing.expect(model.seq_fc26_zero < model.seq_patch_start);
    try std.testing.expect(model.seq_patch_start < model.seq_fc26_enable);
    try std.testing.expect(model.seq_fc26_enable < model.seq_breakpoints_done);
    // Endzustand: Patch aktiv, erster Patchvektor und Breakpoints exakt.
    try std.testing.expectEqual(@as(u16, 0x8000), model.mac_ocp[0xFC26 / 2]);
    try std.testing.expectEqual(@as(u16, 0xE008), model.mac_ocp[0xF800 / 2]);
    try std.testing.expectEqual(@as(u16, 0x0297), model.mac_ocp[0xFC2C / 2]);
    try std.testing.expectEqual(@as(u16, 0x08DF), model.mac_ocp[0xFC36 / 2]);
    // Der Bind selbst bleibt reset-frei und bewegt weiter Verkehr.
    try std.testing.expectEqual(@as(u32, 0), model.reset_count);
    try std.testing.expect(deliverFrame(&test_frame));
    pollBackend();
    try std.testing.expectEqual(@as(u32, 1), model.received_frames);
}

test "fw=on writes the phy ram code under the handshake and marks the version" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .opt_fw = .on }));
    try std.testing.expect(logContains("RTL8168.R4D fw phy ram-code loaded ops=38"));
    try std.testing.expect(!logContains("fw phy patch-request timeout"));
    // RAM-Code angekommen, Versionsmarker gesetzt, Patchfenster geschlossen.
    try std.testing.expectEqual(@as(u16, 0x107C), model.phy_params[0xA000]);
    try std.testing.expectEqual(@as(u16, 0x0210), model.phy_params[0xB820]);
    try std.testing.expectEqual(@as(u16, 0x0000), model.phy_params[0x8146]);
    try std.testing.expectEqual(@as(u16, 0x0001), model.phy_params[0x801E]);
    // Patch-Request wieder geloest (Seite 0x0B82 Reg 0x10 Bit 4 geloescht).
    try std.testing.expectEqual(@as(u16, 0), model.gphy_ocp[0xB820 / 2] & (1 << 4));
}

test "fw=on skips a current phy ram code while refreshing the mac patch" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .opt_fw = .on, .phy_ram_code_current = true }));
    try std.testing.expect(logContains("RTL8168.R4D fw mac-mcu loaded words=417"));
    try std.testing.expect(logContains("RTL8168.R4D fw phy ram-code current; skipped"));
    try std.testing.expect(!logContains("fw phy ram-code loaded"));
    // Der PHY-RAM-Code wurde nicht angefasst.
    try std.testing.expectEqual(@as(u16, 0), model.phy_params[0xA000]);
}

test "fw=force reloads the phy ram code despite a current marker" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .opt_fw = .force, .phy_ram_code_current = true }));
    try std.testing.expect(logContains("options msi=on irq=on fw=force"));
    try std.testing.expect(logContains("RTL8168.R4D fw phy ram-code loaded ops=38"));
    try std.testing.expectEqual(@as(u16, 0x107C), model.phy_params[0xA000]);
    try std.testing.expectEqual(@as(u16, 0x0001), model.phy_params[0x801E]);
}

test "warm tx-stall escalation performs the reference takeover and revives the datapath" {
    // Reales 0.59.23-Warmbild: PHY lebt, Firmware laedt, aber die TX-Engine
    // stallt im Firmware-FIFO-Besitz. Nach zwei echten Stall-Recoveries muss
    // die Warmfix-Eskalation Ownership-Handoff, Firmware force, PHY-Reset
    // und die Referenz-Startkette fahren - danach lebt der Datenpfad.
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{
        .warm_oob = true,
        .warm_stall = true,
        .opt_fw = .on,
        .opt_warmfix = true,
        .phy_ram_code_current = true,
    }));
    try std.testing.expect(logContains("options msi=on irq=on fw=on warmfix=on"));
    try std.testing.expect(model.fifo_owner == .firmware);

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        model.sim_ticks +%= 5001;
        _ = deliverFrame(&test_frame);
        pollBackend();
        if (model.received_frames > 0 and logContains("RTL8168.R4D tx canary confirmed")) break;
    }

    // Uebernahme gelaufen und wirksam.
    try std.testing.expect(logContains("RTL8168.R4D warmfix takeover applied"));
    try std.testing.expect(model.fifo_owner == .driver_mode);
    try std.testing.expect(model.now_is_oob_cleared);
    // Firmware wurde in der Eskalation trotz aktuellem Marker neu geladen.
    try std.testing.expect(logContains("RTL8168.R4D fw phy ram-code loaded ops=38"));
    try std.testing.expect(model.phy_reset_seen);
    // Referenz-Startkette: ERI-FIFO-Schwellen, EPHY-Baseline, AUTO_FIFO,
    // EarlySize 0x27 und VER_40-RxConfig.
    try std.testing.expectEqual(@as(u32, 0x0008_0002), model.eri[0xC8 / 4]);
    try std.testing.expectEqual(@as(u32, 0x0010_0006), model.eri[0xE8 / 4]);
    try std.testing.expectEqual(@as(u32, 0x38), model.eri[0xCC / 4] & 0xFF);
    try std.testing.expectEqual(@as(u32, 0x48), model.eri[0xD0 / 4] & 0xFF);
    try std.testing.expectEqual(@as(u16, 0x7C00), model.ephy[0x19]);
    try std.testing.expect((model.recorded_tx_config & (1 << 7)) != 0);
    try std.testing.expectEqual(@as(u8, 0x27), model.recorded_max_tx_packet);
    try std.testing.expect((model.recorded_rx_config & (1 << 15)) != 0);
    try std.testing.expect((model.recorded_rx_config & (1 << 11)) != 0);
    // Der Datenpfad lebt: Sendung auf dem Draht, Empfang zugestellt.
    try std.testing.expect(logContains("RTL8168.R4D tx canary confirmed"));
    try std.testing.expect(model.wire_tx_frames > 0);
    try std.testing.expect(model.received_frames > 0);
}

test "warm bridge bus-master loss is repaired at bind and dma works immediately" {
    // Real bestaetigte Root Cause: Root-Port-BME nach ACPI-Warmreset weg ->
    // MMIO lebt, aber TX-Fetch/RX-Write/MSI (Upstream) sterben. Die
    // Reparatur ist STANDARDVERHALTEN am Bind (keine Option noetig,
    // Linux pci_enable_bridge-Semantik; der Recovery-Taskkontext crasht
    // real bei PCI-Fremdzugriffen). Danach arbeitet der Datenpfad SOFORT -
    // ohne einen einzigen Stall.
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{
        .bridge_bme_off = true,
    }));
    // Beweisspur und Reparatur bereits am Bind.
    try std.testing.expect(logContains("RTL8168.R4D warmfix pci endpoint=0x"));
    try std.testing.expect(logContains(" bridge=0x0002 -> 0x0006"));
    try std.testing.expectEqual(@as(u32, 0x0006), model.bridge_command);

    var round: usize = 0;
    while (round < 6) : (round += 1) {
        model.sim_ticks +%= 2501;
        _ = deliverFrame(&test_frame);
        pollBackend();
    }

    // Kein Stall, keine Eskalation - der Bind hat geheilt.
    try std.testing.expect(!logContains("recovery cause="));
    try std.testing.expect(!logContains("warmfix takeover"));
    try std.testing.expect(logContains("RTL8168.R4D tx canary confirmed"));
    try std.testing.expect(model.wire_tx_frames > 0);
    try std.testing.expect(model.received_frames > 0);
}

test "cold boots never trigger the warmfix escalation" {
    // Gesunder Kaltbind mit aktivierter Option: ohne echte TX-Stalls darf
    // die Eskalation nie laufen; der Bind bleibt reset- und eskalationsfrei.
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{ .opt_fw = .on, .opt_warmfix = true }));
    var round: usize = 0;
    while (round < 6) : (round += 1) {
        model.sim_ticks +%= 2501;
        _ = deliverFrame(&test_frame);
        pollBackend();
    }
    try std.testing.expect(logContains("RTL8168.R4D tx canary confirmed"));
    try std.testing.expect(!logContains("warmfix takeover"));
    try std.testing.expect(!logContains("recovery cause="));
    try std.testing.expectEqual(@as(u32, 0), model.eri_write_count);
    try std.testing.expectEqual(@as(u32, 0), model.ephy_write_count);
    try std.testing.expectEqual(@as(u32, 0), model.reset_count);
    // Legacy-Startwerte unveraendert.
    try std.testing.expectEqual(LEGACY_TX_CONFIG, model.recorded_tx_config);
    try std.testing.expectEqual(@as(u8, 0x3F), model.recorded_max_tx_packet);
}

test "transition shutdown parks the MAC reset-free and holds the DMA region" {
    try std.testing.expectEqual(@as(i32, 0), bindDriver(.{}));
    const resets_before = model.reset_count;
    try std.testing.expectEqual(@as(i32, 0), driver.rtl8168_shutdown());
    try std.testing.expect(!busMasterOn());
    // Reset-frei auch im Uebergabepfad; Engines aus, DMA-Region gehalten.
    try std.testing.expectEqual(resets_before, model.reset_count);
    try std.testing.expectEqual(@as(u32, 0), model.free_dma_calls);
    const chip = rawRead(REG_CHIP_COMMAND, u8);
    try std.testing.expectEqual(@as(u8, 0), chip & (CHIP_COMMAND_RX_ENABLE | CHIP_COMMAND_TX_ENABLE));

    // Idempotenz: ein zweiter Transition-Aufruf liefert das gecachte sichere
    // Ergebnis, ohne den Controller erneut anzufassen.
    try std.testing.expectEqual(@as(i32, 0), driver.rtl8168_shutdown());
    try std.testing.expectEqual(resets_before, model.reset_count);
}
