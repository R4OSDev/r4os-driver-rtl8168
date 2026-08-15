const builtin = @import("builtin");
const r4os = @import("r4os");
const contract = @import("rtl8168_contract.zig");
const firmware = @import("rtl8168_firmware.zig");
const warmfix = @import("rtl8168_warmfix.zig");

// BEWUSST ENTFERNT (realer Hardwaretest, RTL8168GU XID 0x509):
// Der Bind ist der bewaehrte reset-freie Legacy-Pfad des 0.59.5-Treibers,
// der auf dem Lenovo wochenlang stabile Kaltstarts mit DHCP und statischer
// IP geliefert hat. Alle spaeter ergaenzten Datenpfad-Eingriffe beim Bind
// haben genau diese Stabilitaet gebrochen (boot-abhaengige Totalausfaelle
// bei identischer Software) und sind bewusst entfernt:
//   - CmdReset im Bind und OOB-/Shared-FIFO-Handoff (NOW_IS_OOB, E8DE)
//   - ERI-/EPHY-/MAC-OCP-Baseline, RealWoW-Parken, Exit-L1-Events
//   - TXCFG_AUTO_FIFO, EarlySize 0x27, RxConfig-Familienbits
//   - MCU-BPS-Eingriffe (stoppen die laufende ROM-MCU) und PHY-Softreset
// Ein Wiedereinbau braucht Feature fuer Feature einen realen Mehrboot-
// Kaltstartnachweis gegen diesen Stand. Der Warmreboot ist plattformseitig
// (NIC-Zustand ueberlebt kurze Stromzyklen); er wird nicht im Bind geloest.
// Behalten und real bewiesen: MSI (irq=24), kalibrierte Recovery (PCSTimeout
// nur zaehlen), TX-Kanarienvogel/RX-Marker, Transition-Shutdown.

comptime {
    // Der R4D-Entry-Stub existiert nur im echten Modulbuild. Ein
    // Host-Testbuild (rtl8168_host_model.zig) linkt keinen R4D-Einstieg.
    if (!builtin.is_test) {
        asm (r4os.r4dev.driverEntriesAsm("rtl8168_init", "rtl8168_shutdown"));
    }
}

// Host-Testseam fuer MMIO. Im Produktionsbuild ist der Hook-Typ leer und
// jeder Zugriff kompiliert unveraendert zum direkten volatile
// Pointerzugriff; nur ein Testbuild kann ein aktives Registermodell setzen.
pub const TestMmioHooks = struct {
    read8: *const fn (u64) u8,
    read16: *const fn (u64) u16,
    read32: *const fn (u64) u32,
    write8: *const fn (u64, u8) void,
    write16: *const fn (u64, u16) void,
    write32: *const fn (u64, u32) void,
};
pub var test_mmio_hooks: if (builtin.is_test) ?*const TestMmioHooks else void =
    if (builtin.is_test) null else {};

const REG_MAC0: u64 = 0x00;
const REG_MAC4: u64 = 0x04;
const REG_TX_DESC_LOW: u64 = 0x20;
const REG_TX_DESC_HIGH: u64 = 0x24;
const REG_CHIP_COMMAND: u64 = 0x37;
const REG_TX_POLL: u64 = 0x38;
const REG_INTERRUPT_MASK: u64 = 0x3C;
const REG_INTERRUPT_STATUS: u64 = 0x3E;
const REG_TX_CONFIG: u64 = 0x40;
const REG_RX_CONFIG: u64 = 0x44;
const REG_CFG9346: u64 = 0x50;
const REG_PHY_ACCESS: u64 = 0x60;
const REG_PHY_STATUS: u64 = 0x6C;
const REG_GPHY_OCP: u64 = 0xB8;
const REG_MISC: u64 = 0xF0;
const REG_RX_MAX_SIZE: u64 = 0xDA;
const REG_CPLUS_COMMAND: u64 = 0xE0;
const REG_INTERRUPT_MITIGATE: u64 = 0xE2;
const REG_RX_DESC_LOW: u64 = 0xE4;
const REG_RX_DESC_HIGH: u64 = 0xE8;
const REG_MAX_TX_PACKET_SIZE: u64 = 0xEC;

const CHIP_COMMAND_RESET: u8 = 0x10;
const CHIP_COMMAND_RX_ENABLE: u8 = 0x08;
const CHIP_COMMAND_TX_ENABLE: u8 = 0x04;
const TX_POLL_NORMAL_QUEUE: u8 = 0x40;

const INTERRUPT_SYSTEM_ERROR: u16 = 0x8000;
const INTERRUPT_PCS_TIMEOUT: u16 = 0x4000;
const INTERRUPT_TX_DESC_UNAVAILABLE: u16 = 0x0080;
const INTERRUPT_RX_FIFO_OVERFLOW: u16 = 0x0040;
const INTERRUPT_LINK_CHANGE: u16 = 0x0020;
const INTERRUPT_RX_OVERFLOW: u16 = 0x0010;
const INTERRUPT_TX_ERROR: u16 = 0x0008;
const INTERRUPT_TX_OK: u16 = 0x0004;
const INTERRUPT_RX_ERROR: u16 = 0x0002;
const INTERRUPT_RX_OK: u16 = 0x0001;
const INTERRUPT_ACTIVE: u16 = INTERRUPT_SYSTEM_ERROR |
    INTERRUPT_PCS_TIMEOUT |
    INTERRUPT_TX_DESC_UNAVAILABLE |
    INTERRUPT_RX_FIFO_OVERFLOW |
    INTERRUPT_LINK_CHANGE |
    INTERRUPT_RX_OVERFLOW |
    INTERRUPT_TX_ERROR |
    INTERRUPT_TX_OK |
    INTERRUPT_RX_ERROR |
    INTERRUPT_RX_OK;

// Kalibrierte Ereignismaske fuer die G-Familie: SYSErr/PCSTimeout bleiben
// unmaskiert (upstream irq_mask fuer VER_07+); PCSTimeout hat auf dem realen
// GU als Interruptquelle Dauerfeuer und unnoetige Vollresets erzeugt.
const INTERRUPT_G_FAMILY_EVENTS: u16 = INTERRUPT_LINK_CHANGE |
    INTERRUPT_TX_ERROR |
    INTERRUPT_TX_OK |
    INTERRUPT_RX_ERROR |
    INTERRUPT_RX_OK;

fn interruptEventMask() u16 {
    return if (contract.isRtl8168GFamily(state.xid))
        INTERRUPT_G_FAMILY_EVENTS
    else
        INTERRUPT_ACTIVE;
}

const RX_CONFIG_FIFO_UNLIMITED: u32 = 7 << 13;
const RX_CONFIG_DMA_UNLIMITED: u32 = 7 << 8;
const RX_CONFIG_ACCEPT_BROADCAST: u32 = 1 << 3;
const RX_CONFIG_ACCEPT_MULTICAST: u32 = 1 << 2;
const RX_CONFIG_ACCEPT_PHYSICAL: u32 = 1 << 1;
const RX_CONFIG_ACCEPT_MASK: u32 = 0x3F;
const TX_CONFIG_INTERFRAME_GAP: u32 = 3 << 24;
const TX_CONFIG_DMA_UNLIMITED: u32 = 7 << 8;
const CPLUS_RX_VLAN: u16 = 1 << 6;
const CPLUS_RX_CHECKSUM: u16 = 1 << 5;
const CPLUS_PCI_DAC: u16 = 1 << 4;
const CPLUS_PCI_MULTIPLE_READ_WRITE: u16 = 1 << 3;
const MISC_RXDV_GATED_ENABLE: u32 = 1 << 19;
const PHY_STATUS_LINK: u8 = 1 << 1;

const CFG9346_UNLOCK: u8 = 0xC0;
const CFG9346_LOCK: u8 = 0x00;

const PCI_COMMAND_OFFSET: u16 = 0x04;
const PCI_COMMAND_MEMORY_SPACE: u32 = 1 << 1;
const PCI_COMMAND_BUS_MASTER: u32 = 1 << 2;

const PHY_ACCESS_FLAG: u32 = 1 << 31;
const PHY_ACCESS_REGISTER_SHIFT: u5 = 16;
const GPHY_OCP_WRITE: u32 = 1 << 31;
const GPHY_OCP_FLAG: u32 = 1 << 31;
const GPHY_OCP_BASE: u32 = 0xA400;
const MII_BMCR: u5 = 0;
const BMCR_AUTONEG_ENABLE: u16 = 1 << 12;
const BMCR_POWER_DOWN: u16 = 1 << 11;
const BMCR_ISOLATE: u16 = 1 << 10;
const BMCR_RESTART_AUTONEG: u16 = 1 << 9;

// Exakte GU-Identitaet fuer den optionalen Firmware-Ladepfad; keine
// Familienausweitung ohne eigenen Hardware-Nachweis.
const XID_RTL8168GU: u16 = 0x509;

const TX_DESCRIPTOR_COUNT: usize = 16;
const RX_DESCRIPTOR_COUNT: usize = 64;
const DMA_BUFFER_BYTES: usize = 2048;
const MAX_FRAME_BYTES: usize = 1514;
const MIN_FRAME_BYTES: usize = 60;
const RX_DRAIN_BUDGET: usize = RX_DESCRIPTOR_COUNT;
const TX_RING_OFFSET: usize = 0;
const RX_RING_OFFSET: usize = alignUp(TX_RING_OFFSET + TX_DESCRIPTOR_COUNT * @sizeOf(contract.Descriptor), 256);
const TX_BUFFERS_OFFSET: usize = alignUp(RX_RING_OFFSET + RX_DESCRIPTOR_COUNT * @sizeOf(contract.Descriptor), 256);
const RX_BUFFERS_OFFSET: usize = alignUp(TX_BUFFERS_OFFSET + TX_DESCRIPTOR_COUNT * DMA_BUFFER_BYTES, 256);
const DMA_BYTES: u32 = @intCast(RX_BUFFERS_OFFSET + RX_DESCRIPTOR_COUNT * DMA_BUFFER_BYTES);
const MMIO_BYTES: u32 = 4096;
const IRQ_ROUTE_CAPACITY: usize = 10;
// Reale Verzoegerungen (Autoneg, Switch-Lernphase) duerfen keinen Reset
// ausloesen; erst ab fuenf Sekunden gilt eine Sendung als steckengeblieben.
const TX_STUCK_MILLISECONDS: u32 = 5000;
const CANARY_INTERVAL_MILLISECONDS: u32 = 2000;
const CANARY_ETHERTYPE_HIGH: u8 = 0x88;
const CANARY_ETHERTYPE_LOW: u8 = 0xB5;
const PCI_CAPABILITY_STEPS: usize = 48;
const SHUTDOWN_SOFTWARE_IDLE_MILLISECONDS: u32 = 100;
const CONTROLLER_RESET_MILLISECONDS: u32 = 100;

const State = struct {
    api: *const r4os.r4dev.DriverApi = undefined,
    active: bool = false,
    registered: bool = false,
    transition_shutdown_done: bool = false,
    transition_shutdown_safe: bool = false,
    pci_device_found: bool = false,
    info: r4os.abi.PciDeviceInfo = .{},
    mmio: r4os.abi.MmioRegion = .{},
    dma: r4os.abi.DmaBuffer = .{},
    adapter_index: i32 = -1,
    mac: [6]u8 = .{0} ** 6,
    revision: u8 = 0,
    subsystem_vendor: u16 = 0,
    subsystem_device: u16 = 0,
    xid: u16 = 0,
    phy_family: contract.PhyFamily = .preserve_firmware,
    phy_autoneg_requested: bool = false,
    pm_capability: u8 = 0,
    pcie_capability: u8 = 0,
    pm_d0_transitioned: bool = false,
    pcie_l1_disabled: bool = false,
    rx_head: usize = 0,
    tx_head: usize = 0,
    tx_pending: [TX_DESCRIPTOR_COUNT]bool = .{false} ** TX_DESCRIPTOR_COUNT,
    tx_pending_since: [TX_DESCRIPTOR_COUNT]u64 = .{0} ** TX_DESCRIPTOR_COUNT,
    tx_stuck_ticks: u64 = 0,
    tx_lock: bool = false,
    poll_active: bool = false,
    poll_hint: bool = false,
    recovery_pending: bool = false,
    recovery_active: bool = false,
    rx_ok: u64 = 0,
    tx_ok: u64 = 0,
    rx_errors: u64 = 0,
    tx_errors: u64 = 0,
    rx_overflows: u64 = 0,
    rx_drops: u64 = 0,
    poll_count: u64 = 0,
    poll_fallbacks: u64 = 0,
    irq_registered: bool = false,
    irq_mode: u8 = 0,
    irq_routes: [IRQ_ROUTE_CAPACITY]u8 = .{0xFF} ** IRQ_ROUTE_CAPACITY,
    irq_route_count: usize = 0,
    irq_active_route: u8 = 0xFF,
    irq_count: u64 = 0,
    irq_handled: u64 = 0,
    irq_unhandled: u64 = 0,
    last_isr: u16 = 0,
    hard_resets: u64 = 0,
    tx_stuck_recoveries: u64 = 0,
    // TX-Kanarienvogel: fuettert die Stall-Erkennung ohne externen Verkehr
    // (Miniframe an die eigene MAC), bis der Sendepfad erstmals nachweislich
    // abgeschlossen hat. Reine Diagnose, kein Eingriffsarm.
    tx_confirmed: bool = false,
    canary_last_tick: u64 = 0,
    canary_interval_ticks: u64 = 0,
    canary_frames: u64 = 0,
    rx_confirmed: bool = false,
    // Getrennte Ursachen-Telemetrie fuer Recovery und Ereignisse.
    recovery_cause_syserr: bool = false,
    stall_recoveries: u64 = 0,
    syserr_recoveries: u64 = 0,
    syserr_events: u64 = 0,
    pcs_timeout_events: u64 = 0,
    link_reported: bool = false,
    link_last: bool = false,
    link_changes: u64 = 0,
    // Warmfix-Eskalation (0.59.24): zaehlt echte TX-Stall-Recoveries und
    // traegt den einmaligen Referenz-Uebernahmezustand. Kaltboots erreichen
    // diesen Pfad nie (7/7 reale Boots ohne einen einzigen Stall).
    warmfix_stalls: u8 = 0,
    warmfix_attempted: bool = false,
    warmfix_active: bool = false,
};

var state: State = .{};
var backend: r4os.abi.NetBackend = .{};

pub export fn rtl8168_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    state = .{ .api = api };
    backend = .{};
    var ctx = context();
    ctx.logInfo("RTL8168.R4D init");

    const info = findDevice(&ctx) orelse {
        ctx.logWarn("RTL8168.R4D device 10EC:8168 not found");
        return -1;
    };
    state.info = info;
    state.pci_device_found = true;
    readPciIdentity(&ctx);
    walkPciCapabilities(&ctx);

    if (ctx.pciEnableBusMaster(info, r4os.abi.pci_enable_memory_space) != 0) {
        ctx.logError("RTL8168.R4D memory/bus-master enable failed");
        return -2;
    }
    if (!mapRegisterBar(&ctx, info)) {
        ctx.logError("RTL8168.R4D missing usable MMIO BAR");
        return -3;
    }

    readMac();
    if (!validMac(state.mac)) {
        ctx.logError("RTL8168.R4D invalid hardware MAC");
        return -4;
    }
    state.xid = contract.xidFromTxConfig(mmioRead32(REG_TX_CONFIG));
    state.phy_family = contract.phyFamilyForXid(state.xid);
    logXidIdentity(&ctx);
    logFeatureConfiguration(&ctx);

    // Firmware-Ladepfad (MCU-Patch + PHY-RAM-Code): nur die exakte
    // GU-Identitaet und nur per expliziter Option. Der reset-freie Bind
    // selbst bleibt in jedem Modus unveraendert.
    const fw_mode = fwMode(&ctx);
    if (fw_mode != .off and state.xid == XID_RTL8168GU) {
        _ = firmware.load(&fw_access, fw_mode);
    }
    // Bridge-Check am BIND, IMMER fuer die exakte GU-Identitaet (Entscheid
    // nach dem realen 0.59.24-Durchbruch): Der ACPI-Warmreset dieses Ziels
    // loescht das Bus-Master-Enable im Root-Port; ohne Reparatur sterben
    // alle NIC-initiierten Upstream-Zugriffe. Linux pci_enable_bridge-
    // Semantik: auf gesunden Boots ein No-Op, sonst wird Memory+Bus-Master
    // gesetzt, BEVOR Ringe oder Engines existieren. Laeuft nur im
    // Init-Kontext (PCI-Fremdzugriffe aus dem Taskkontext crashen real).
    if (state.xid == XID_RTL8168GU) {
        warmfixBridgeAtBind(&ctx);
    }

    if (ctx.allocDmaRegion(DMA_BYTES, 4096, &state.dma) != 0 or state.dma.phys_addr == 0 or state.dma.virt_addr == 0) {
        ctx.logError("RTL8168.R4D DMA allocation failed");
        return -5;
    }
    state.tx_stuck_ticks = contract.ticksForMilliseconds(ctx.timerFrequency(), TX_STUCK_MILLISECONDS);
    if (state.tx_stuck_ticks == 0) state.tx_stuck_ticks = 300;
    state.canary_interval_ticks = contract.ticksForMilliseconds(ctx.timerFrequency(), CANARY_INTERVAL_MILLISECONDS);
    if (state.canary_interval_ticks == 0) state.canary_interval_ticks = 120;

    requestBasicAutoneg(&ctx);
    if (!initializeHardware(&ctx, false)) {
        ctx.logError("RTL8168.R4D hardware initialization failed");
        shutdownHardware(&ctx);
        return -6;
    }

    backend = .{};
    backend.version = r4os.abi.net_backend_version;
    backend.size = @sizeOf(r4os.abi.NetBackend);
    // Keep the adapter eligible while autoneg is still settling. Runtime link
    // truth is reported through status(); rejecting early DHCP traffic here
    // would permanently park the adapter before the first link-up transition.
    backend.flags = r4os.abi.net_backend_flag_broadcast |
        r4os.abi.net_backend_flag_trusted |
        r4os.abi.net_backend_flag_link_up;
    backend.mtu = 1500;
    backend.bus_kind = info.bus_kind;
    backend.bus = info.bus;
    backend.device = info.device;
    backend.function = info.function;
    backend.vendor_id = info.vendor_id;
    backend.device_id = info.device_id;
    backend.mac = state.mac;
    backend.context = &state;
    backend.transmit = transmit;
    backend.poll = poll;
    backend.shutdown = backendShutdown;
    backend.status = status;

    const adapter = ctx.registerNetBackend("rtl8168", &backend);
    if (adapter < 0) {
        ctx.logError("RTL8168.R4D register_net_backend failed");
        shutdownHardware(&ctx);
        return -7;
    }
    state.adapter_index = adapter;
    state.registered = true;
    state.active = true;
    setupInterrupts(&ctx);
    ctx.logInfo("RTL8168.R4D registered");
    return 0;
}

pub export fn rtl8168_shutdown() callconv(.c) i32 {
    var ctx = context();
    ctx.logInfo("RTL8168.R4D shutdown");
    if (state.transition_shutdown_done) return if (state.transition_shutdown_safe) 0 else -1;
    const safe = shutdownHardwareForTransition(&ctx);
    state.transition_shutdown_safe = safe;
    state.transition_shutdown_done = true;
    return if (safe) 0 else -1;
}

fn context() r4os.r4dev.DriverContext {
    return r4os.r4dev.DriverContext.init(state.api);
}

fn findDevice(ctx: *const r4os.r4dev.DriverContext) ?r4os.abi.PciDeviceInfo {
    var index: u32 = 0;
    const count = ctx.pciDeviceCount();
    while (index < count) : (index += 1) {
        var info: r4os.abi.PciDeviceInfo = .{};
        if (ctx.pciDeviceAt(index, &info) != 0) continue;
        if (info.vendor_id == contract.vendor_realtek and info.device_id == contract.device_rtl8168) return info;
    }
    return null;
}

fn mapRegisterBar(ctx: *const r4os.r4dev.DriverContext, info: r4os.abi.PciDeviceInfo) bool {
    // Real RTL8168 systems normally expose the register window in BAR2.
    // Firmware variants are allowed to place it in another memory BAR, so
    // retain BAR2 priority and then try every other real BAR (never the high
    // half of a 64-bit BAR pair).
    const candidates = [_]u8{ 2, 0, 1, 3, 4, 5 };
    for (candidates) |bar| {
        if (!isMemoryBarStart(ctx, info, bar)) continue;
        var region: r4os.abi.MmioRegion = .{};
        if (ctx.pciMapBar(info, bar, MMIO_BYTES, 0, &region) == 0 and region.virt_addr != 0) {
            state.mmio = region;
            return true;
        }
    }
    return false;
}

fn isMemoryBarStart(ctx: *const r4os.r4dev.DriverContext, info: r4os.abi.PciDeviceInfo, target: u8) bool {
    var index: u8 = 0;
    while (index < 6) {
        const raw = ctx.pciReadBar(info, index);
        const valid = raw != 0 and raw != 0xFFFF_FFFF;
        const memory = valid and (raw & 1) == 0;
        if (index == target) return memory;
        if (memory and ((raw >> 1) & 3) == 2 and index + 1 < 6) {
            index += 2;
        } else {
            index += 1;
        }
    }
    return false;
}

fn readPciIdentity(ctx: *const r4os.r4dev.DriverContext) void {
    const class_revision = ctx.pciReadConfig32(state.info, 0x08);
    const subsystem = ctx.pciReadConfig32(state.info, 0x2C);
    state.revision = @truncate(class_revision);
    state.subsystem_vendor = @truncate(subsystem);
    state.subsystem_device = @truncate(subsystem >> 16);
    if (state.subsystem_vendor == contract.target_subsystem_vendor and
        state.subsystem_device == contract.target_subsystem_device and
        state.revision == contract.target_revision)
    {
        ctx.logInfo("RTL8168.R4D Lenovo 17AA:38C7 rev 10 target detected");
    } else {
        ctx.logWarn("RTL8168.R4D generic 10EC:8168 compatibility probe");
    }
}

fn walkPciCapabilities(ctx: *const r4os.r4dev.DriverContext) void {
    const command_status = ctx.pciReadConfig32(state.info, 0x04);
    if ((command_status & (@as(u32, 1) << 20)) == 0) return;
    var offset = contract.capabilityOffset(ctx.pciReadConfig32(state.info, 0x34));
    var visited: [64]bool = .{false} ** 64;
    var steps: usize = 0;
    while (contract.validCapabilityOffset(offset) and steps < PCI_CAPABILITY_STEPS) : (steps += 1) {
        const slot = offset / 4;
        if (visited[slot]) break;
        visited[slot] = true;
        const header = ctx.pciReadConfig32(state.info, offset);
        if (header == 0xFFFF_FFFF) break;
        const capability_id: u8 = @truncate(header);
        if (capability_id == 0x01 and offset <= 0xF8 and state.pm_capability == 0) {
            state.pm_capability = offset;
        } else if (capability_id == 0x10 and offset <= 0xEC and state.pcie_capability == 0) {
            state.pcie_capability = offset;
        }
        const next = contract.nextCapabilityOffset(header);
        if (next == 0 or next == offset) break;
        offset = next;
    }

    // Capability list order is firmware-defined. Apply power management only
    // after discovery, and always establish/verify D0 before touching PCIe
    // Link Control.
    var d0_ready = true;
    if (state.pm_capability != 0) {
        const pmcsr_offset: u16 = @as(u16, state.pm_capability) + 4;
        const pmcsr = ctx.pciReadConfig32(state.info, pmcsr_offset);
        if (pmcsr == 0xFFFF_FFFF) {
            d0_ready = false;
        } else if ((pmcsr & 3) != 0) {
            if (ctx.pciWriteConfig32(state.info, pmcsr_offset, contract.pmD0WriteValue(pmcsr)) != 0) {
                d0_ready = false;
            } else {
                const settle_ticks = contract.ticksForMilliseconds(ctx.timerFrequency(), 10);
                if (settle_ticks > 0) ctx.waitTicks(settle_ticks);
                const verified = ctx.pciReadConfig32(state.info, pmcsr_offset);
                d0_ready = verified != 0xFFFF_FFFF and (verified & 3) == 0;
                state.pm_d0_transitioned = d0_ready;
            }
        }
        if (!d0_ready) ctx.logWarn("RTL8168.R4D PCI PM D0 transition failed");
    }

    if (d0_ready and state.pcie_capability != 0) {
        const link_control_offset: u16 = @as(u16, state.pcie_capability) + 0x10;
        const link_control = ctx.pciReadConfig32(state.info, link_control_offset);
        if (link_control != 0xFFFF_FFFF and
            ctx.pciWriteConfig32(state.info, link_control_offset, contract.pcieEndpointL1DisabledWriteValue(link_control)) == 0)
        {
            const verified = ctx.pciReadConfig32(state.info, link_control_offset);
            state.pcie_l1_disabled = verified != 0xFFFF_FFFF and (verified & 2) == 0;
        }
        if (!state.pcie_l1_disabled) ctx.logWarn("RTL8168.R4D PCIe endpoint L1 disable failed");
    }
}

fn logXidIdentity(ctx: *const r4os.r4dev.DriverContext) void {
    // Die XID-Zeile beweist im realen Bootlog, welche Chip-Identitaet der
    // Treiber gebunden hat; genau diese Spur fehlte bei der langen
    // 0x509-vs-8168H-Fehlsuche.
    var buf: [64]u8 = .{0} ** 64;
    var len: usize = 0;
    for ("RTL8168.R4D xid=0x") |c| {
        buf[len] = c;
        len += 1;
    }
    const digits = "0123456789ABCDEF";
    buf[len] = digits[(state.xid >> 8) & 0xF];
    buf[len + 1] = digits[(state.xid >> 4) & 0xF];
    buf[len + 2] = digits[state.xid & 0xF];
    len += 3;
    const family: []const u8 = switch (state.phy_family) {
        .gphy_ocp => " phy=gphy-ocp",
        .phyar => " phy=phyar",
        .preserve_firmware => " phy=firmware-preserve",
    };
    for (family) |c| {
        buf[len] = c;
        len += 1;
    }
    for (" bind=reset-free") |c| {
        buf[len] = c;
        len += 1;
    }
    ctx.logInfo(buf[0..len :0].ptr);
}

fn logFeatureConfiguration(ctx: *const r4os.r4dev.DriverContext) void {
    // Die Schalterstellung dokumentiert sich selbst im Bootlog.
    var buf: [96]u8 = .{0} ** 96;
    var len: usize = 0;
    for ("RTL8168.R4D options") |c| {
        buf[len] = c;
        len += 1;
    }
    const entries = [_]struct { name: []const u8, off: bool }{
        .{ .name = "msi", .off = msiDisabled(ctx) },
        .{ .name = "irq", .off = irqDisabled(ctx) },
    };
    for (entries) |entry| {
        buf[len] = ' ';
        len += 1;
        for (entry.name) |c| {
            buf[len] = c;
            len += 1;
        }
        const value: []const u8 = if (entry.off) "=off" else "=on";
        for (value) |c| {
            buf[len] = c;
            len += 1;
        }
    }
    const fw_text: []const u8 = switch (fwMode(ctx)) {
        .off => " fw=off",
        .on => " fw=on",
        .force => " fw=force",
    };
    for (fw_text) |c| {
        buf[len] = c;
        len += 1;
    }
    const warmfix_text: []const u8 = if (warmfixEnabled(ctx)) " warmfix=on" else " warmfix=off";
    for (warmfix_text) |c| {
        buf[len] = c;
        len += 1;
    }
    ctx.logInfo(buf[0..len :0].ptr);
}

fn requestBasicAutoneg(ctx: *const r4os.r4dev.DriverContext) void {
    if (linkUp()) return;
    const current = phyRead(MII_BMCR) orelse {
        if (state.phy_family == .preserve_firmware) {
            ctx.logWarn("RTL8168.R4D unknown XID; preserving firmware PHY state");
        } else {
            ctx.logWarn("RTL8168.R4D PHY read failed; preserving firmware state");
        }
        return;
    };
    const requested = (current & ~@as(u16, BMCR_POWER_DOWN | BMCR_ISOLATE)) |
        BMCR_AUTONEG_ENABLE |
        BMCR_RESTART_AUTONEG;
    state.phy_autoneg_requested = phyWrite(MII_BMCR, requested);
    if (!state.phy_autoneg_requested) ctx.logWarn("RTL8168.R4D PHY autoneg request failed");
}

fn phyRead(reg: u5) ?u16 {
    return switch (state.phy_family) {
        .phyar => phyArRead(reg),
        .gphy_ocp => gphyOcpRead(reg),
        .preserve_firmware => null,
    };
}

fn phyWrite(reg: u5, value: u16) bool {
    return switch (state.phy_family) {
        .phyar => phyArWrite(reg, value),
        .gphy_ocp => gphyOcpWrite(reg, value),
        .preserve_firmware => false,
    };
}

fn phyArRead(reg: u5) ?u16 {
    mmioWrite32(REG_PHY_ACCESS, @as(u32, reg) << PHY_ACCESS_REGISTER_SHIFT);
    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) {
        const value = mmioRead32(REG_PHY_ACCESS);
        if ((value & PHY_ACCESS_FLAG) != 0) return @truncate(value);
    }
    return null;
}

fn phyArWrite(reg: u5, value: u16) bool {
    mmioWrite32(REG_PHY_ACCESS, PHY_ACCESS_FLAG | (@as(u32, reg) << PHY_ACCESS_REGISTER_SHIFT) | value);
    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) {
        if ((mmioRead32(REG_PHY_ACCESS) & PHY_ACCESS_FLAG) == 0) return true;
    }
    return false;
}

fn gphyOcpAddress(reg: u5) u32 {
    return GPHY_OCP_BASE + @as(u32, reg) * 2;
}

fn gphyOcpRead(reg: u5) ?u16 {
    mmioWrite32(REG_GPHY_OCP, gphyOcpAddress(reg) << 15);
    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) {
        const value = mmioRead32(REG_GPHY_OCP);
        if ((value & GPHY_OCP_FLAG) != 0) return @truncate(value);
        cpuRelax();
    }
    return null;
}

fn gphyOcpWrite(reg: u5, value: u16) bool {
    mmioWrite32(REG_GPHY_OCP, GPHY_OCP_WRITE | (gphyOcpAddress(reg) << 15) | value);
    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) {
        if ((mmioRead32(REG_GPHY_OCP) & GPHY_OCP_FLAG) == 0) return true;
        cpuRelax();
    }
    return false;
}

fn initializeHardware(ctx: *const r4os.r4dev.DriverContext, after_hard_reset: bool) bool {
    if (state.mmio.virt_addr == 0 or state.dma.virt_addr == 0) return false;
    mmioWrite16(REG_INTERRUPT_MASK, 0);
    mmioWrite16(REG_INTERRUPT_STATUS, 0xFFFF);
    mmioWrite8(REG_CHIP_COMMAND, 0);
    var stop_spin: usize = 0;
    while (stop_spin < 1000) : (stop_spin += 1) {
        if ((mmioRead8(REG_CHIP_COMMAND) & (CHIP_COMMAND_RX_ENABLE | CHIP_COMMAND_TX_ENABLE)) == 0) break;
        cpuRelax();
    }
    if ((mmioRead8(REG_CHIP_COMMAND) & (CHIP_COMMAND_RX_ENABLE | CHIP_COMMAND_TX_ENABLE)) != 0) return false;
    const stop_settle_ticks = contract.ticksForMilliseconds(ctx.timerFrequency(), 1);
    if (stop_settle_ticks > 0) ctx.waitTicks(stop_settle_ticks);

    const misc = mmioRead32(REG_MISC);
    mmioWrite32(REG_MISC, misc & ~@as(u32, MISC_RXDV_GATED_ENABLE));
    initializeDescriptors();

    mmioWrite16(REG_RX_MAX_SIZE, 1522);
    mmioWrite16(REG_INTERRUPT_MITIGATE, 0);
    // Ohne aktivierte Warmfix-Eskalation bleiben dies exakt die bewaehrten
    // Legacy-Werte des reset-freien Kaltbinds; die Referenzwerte kommen
    // ausschliesslich aus dem Warmfix-Modul.
    mmioWrite8(REG_MAX_TX_PACKET_SIZE, if (state.warmfix_active) warmfix.earlyTxSize() else 0x3F);
    var cplus = mmioRead16(REG_CPLUS_COMMAND);
    cplus &= ~@as(u16, CPLUS_RX_VLAN | CPLUS_RX_CHECKSUM);
    cplus |= CPLUS_PCI_DAC | CPLUS_PCI_MULTIPLE_READ_WRITE;
    mmioWrite16(REG_CPLUS_COMMAND, cplus);
    mmioWrite32(REG_TX_CONFIG, if (state.warmfix_active)
        warmfix.txConfigValue()
    else
        TX_CONFIG_INTERFRAME_GAP | TX_CONFIG_DMA_UNLIMITED);
    mmioWrite32(REG_RX_CONFIG, if (state.warmfix_active)
        warmfix.rxConfigValue()
    else
        RX_CONFIG_FIFO_UNLIMITED |
            RX_CONFIG_DMA_UNLIMITED |
            RX_CONFIG_ACCEPT_BROADCAST |
            RX_CONFIG_ACCEPT_MULTICAST |
            RX_CONFIG_ACCEPT_PHYSICAL);

    const tx_ring_phys = state.dma.phys_addr + TX_RING_OFFSET;
    const rx_ring_phys = state.dma.phys_addr + RX_RING_OFFSET;
    // The device may fetch as soon as the low dword is written.
    mmioWrite32(REG_TX_DESC_HIGH, @truncate(tx_ring_phys >> 32));
    mmioWrite32(REG_TX_DESC_LOW, @truncate(tx_ring_phys));
    mmioWrite32(REG_RX_DESC_HIGH, @truncate(rx_ring_phys >> 32));
    mmioWrite32(REG_RX_DESC_LOW, @truncate(rx_ring_phys));
    memoryFence();
    mmioWrite8(REG_CHIP_COMMAND, CHIP_COMMAND_RX_ENABLE | CHIP_COMMAND_TX_ENABLE);
    mmioWrite16(REG_INTERRUPT_STATUS, 0xFFFF);
    if (after_hard_reset) requestBasicAutoneg(ctx);
    return true;
}

fn initializeDescriptors() void {
    state.rx_head = 0;
    state.tx_head = 0;
    var index: usize = 0;
    while (index < TX_DESCRIPTOR_COUNT) : (index += 1) {
        const descriptor = txDescriptor(index);
        descriptor.opts1 = if (index + 1 == TX_DESCRIPTOR_COUNT) contract.descriptor_end_of_ring else 0;
        descriptor.opts2 = 0;
        descriptor.addr = state.dma.phys_addr + TX_BUFFERS_OFFSET + index * DMA_BUFFER_BYTES;
        state.tx_pending[index] = false;
        state.tx_pending_since[index] = 0;
    }
    index = 0;
    while (index < RX_DESCRIPTOR_COUNT) : (index += 1) {
        const descriptor = rxDescriptor(index);
        descriptor.opts2 = 0;
        descriptor.addr = state.dma.phys_addr + RX_BUFFERS_OFFSET + index * DMA_BUFFER_BYTES;
        memoryFence();
        descriptor.opts1 = contract.rxOwnedOptions(DMA_BUFFER_BYTES, index + 1 == RX_DESCRIPTOR_COUNT);
    }
}

fn transmit(raw_context: ?*anyopaque, frame: [*]const u8, len: u32) callconv(.c) i32 {
    const s = stateFrom(raw_context) orelse return 5;
    if (!s.active or s.dma.virt_addr == 0 or s.mmio.virt_addr == 0) return 5;
    if (len == 0 or len > MAX_FRAME_BYTES) return 2;
    if (@atomicLoad(bool, &s.recovery_pending, .acquire) or @atomicLoad(bool, &s.recovery_active, .acquire)) return 1;
    if (@atomicRmw(bool, &s.tx_lock, .Xchg, true, .acq_rel)) return 1;
    defer @atomicStore(bool, &s.tx_lock, false, .release);
    if (!s.active or s.dma.virt_addr == 0 or s.mmio.virt_addr == 0) return 5;

    serviceTxLocked(s);
    if (@atomicLoad(bool, &s.recovery_pending, .acquire)) return 1;
    if (!s.active) return 5;
    const slot = s.tx_head;
    if (s.tx_pending[slot]) return 1;

    const wire_len: usize = @max(@as(usize, len), MIN_FRAME_BYTES);
    const buffer = txBuffer(slot);
    var index: usize = 0;
    while (index < len) : (index += 1) buffer[index] = frame[index];
    while (index < wire_len) : (index += 1) buffer[index] = 0;

    const descriptor = txDescriptor(slot);
    descriptor.opts2 = 0;
    descriptor.addr = s.dma.phys_addr + TX_BUFFERS_OFFSET + slot * DMA_BUFFER_BYTES;
    memoryFence();
    descriptor.opts1 = contract.txOwnedOptions(@intCast(wire_len), slot + 1 == TX_DESCRIPTOR_COUNT);
    memoryFence();
    mmioWrite8(REG_TX_POLL, TX_POLL_NORMAL_QUEUE);

    s.tx_pending[slot] = true;
    s.tx_pending_since[slot] = context().tickCount();
    s.tx_head = (slot + 1) % TX_DESCRIPTOR_COUNT;
    return 0;
}

fn poll(raw_context: ?*anyopaque) callconv(.c) void {
    const s = stateFrom(raw_context) orelse return;
    if (!s.active or s.dma.virt_addr == 0 or s.mmio.virt_addr == 0) return;
    if (@atomicRmw(bool, &s.poll_active, .Xchg, true, .acq_rel)) return;
    defer @atomicStore(bool, &s.poll_active, false, .release);
    if (!s.active or s.dma.virt_addr == 0 or s.mmio.virt_addr == 0) return;
    s.poll_count +%= 1;

    const isr = mmioRead16(REG_INTERRUPT_STATUS);
    if (isr != 0 and isr != 0xFFFF) recordAndAckInterrupt(s, isr, false);
    if (!s.poll_hint) s.poll_fallbacks +%= 1;
    s.poll_hint = false;

    // Linkflanken sichtbar machen. Der DHCP-Koordinator folgt dem Carrier
    // bereits; die Marker machen reale Flaps ohne Paketiteration
    // nachvollziehbar (COM1/Bootlog/LOGSVC).
    const link_now = linkUp();
    if (!s.link_reported or link_now != s.link_last) {
        if (s.link_reported) s.link_changes +%= 1;
        s.link_reported = true;
        s.link_last = link_now;
        const ctx = context();
        ctx.logInfo(if (link_now)
            "RTL8168.R4D link up"
        else
            "RTL8168.R4D link down");
    }

    if (!@atomicRmw(bool, &s.tx_lock, .Xchg, true, .acq_rel)) {
        if (s.active and !@atomicLoad(bool, &s.recovery_pending, .acquire)) serviceTxLocked(s);
        if (s.active and @atomicLoad(bool, &s.recovery_pending, .acquire)) {
            if (recoverTxStall(s)) s.tx_stuck_recoveries +%= 1;
        }
        @atomicStore(bool, &s.tx_lock, false, .release);
    }
    if (s.active and
        !@atomicLoad(bool, &s.recovery_pending, .acquire) and
        !@atomicLoad(bool, &s.recovery_active, .acquire))
    {
        drainRx(s);
        if (!s.tx_confirmed) canaryTick(s);
    }
}

fn logRxConfirmed(ctx: *const r4os.r4dev.DriverContext) void {
    var buf: [96]u8 = .{0} ** 96;
    var len: usize = 0;
    for ("RTL8168.R4D rx path confirmed") |c| {
        buf[len] = c;
        len += 1;
    }
    ctx.logInfo(buf[0..len :0].ptr);
}

fn canaryTick(s: *State) void {
    // Fuettert die Stall-Erkennung ohne externen Verkehr: ein Miniframe an
    // die eigene MAC mit Experimental-EtherType. Ohne diesen Kanarienvogel
    // kann eine kaputte TX-Engine bei statischer Konfiguration unbemerkt
    // bleiben.
    const now = context().tickCount();
    if (now -% s.canary_last_tick < s.canary_interval_ticks) return;
    s.canary_last_tick = now;
    var frame: [60]u8 = .{0} ** 60;
    var index: usize = 0;
    while (index < 6) : (index += 1) {
        frame[index] = s.mac[index];
        frame[6 + index] = s.mac[index];
    }
    frame[12] = CANARY_ETHERTYPE_HIGH;
    frame[13] = CANARY_ETHERTYPE_LOW;
    if (transmit(@ptrCast(s), &frame, frame.len) == 0) s.canary_frames +%= 1;
}

fn logTxConfirmed(ctx: *const r4os.r4dev.DriverContext) void {
    var buf: [96]u8 = .{0} ** 96;
    var len: usize = 0;
    for ("RTL8168.R4D tx canary confirmed") |c| {
        buf[len] = c;
        len += 1;
    }
    len = appendCounter(&buf, len, " canary=", state.canary_frames);
    len = appendCounter(&buf, len, " stalls=", state.stall_recoveries);
    ctx.logInfo(buf[0..len :0].ptr);
}

fn serviceTxLocked(s: *State) void {
    const now = context().tickCount();
    var index: usize = 0;
    while (index < TX_DESCRIPTOR_COUNT) : (index += 1) {
        if (!s.tx_pending[index]) continue;
        const opts1 = txDescriptor(index).opts1;
        if ((opts1 & contract.descriptor_owned) != 0) {
            if (now -% s.tx_pending_since[index] > s.tx_stuck_ticks) {
                s.tx_errors +%= 1;
                @atomicStore(bool, &s.recovery_cause_syserr, false, .release);
                @atomicStore(bool, &s.recovery_pending, true, .release);
                return;
            }
            continue;
        }
        if ((opts1 & contract.tx_error_summary) != 0) {
            s.tx_errors +%= 1;
        } else {
            s.tx_ok +%= 1;
            if (!s.tx_confirmed) {
                // Erste real abgeschlossene Sendung: Der Sendepfad ist
                // bewiesen; der Kanarienvogel endet.
                s.tx_confirmed = true;
                const ctx = context();
                logTxConfirmed(&ctx);
            }
        }
        s.tx_pending[index] = false;
        s.tx_pending_since[index] = 0;
    }
}

fn recoverTxStall(s: *State) bool {
    if (@atomicRmw(bool, &s.recovery_active, .Xchg, true, .acq_rel)) return false;
    defer @atomicStore(bool, &s.recovery_active, false, .release);
    mmioWrite16(REG_INTERRUPT_MASK, 0);
    const cause_syserr = @atomicLoad(bool, &s.recovery_cause_syserr, .acquire);
    @atomicStore(bool, &s.recovery_pending, false, .release);
    var ctx = context();
    // Warmfix-Eskalation (0.59.24): erst nach mehreren echten TX-Stalls,
    // einmal pro Boot, nur per Option und exakter GU-Identitaet. Reihenfolge
    // nach Referenz: Ownership-Uebernahme, Firmware force, PHY-Softreset;
    // die Startkette folgt nach dem Controllerreset unten.
    if (!cause_syserr) {
        s.warmfix_stalls +%= 1;
        // Die Eskalation macht KEINE PCI-Config-Zugriffe (real bewiesener
        // GPF aus dem Taskkontext); der Bridge-Pfad laeuft komplett am Bind.
        if (!s.warmfix_attempted and s.warmfix_stalls >= 2 and
            s.xid == XID_RTL8168GU and warmfixEnabled(&ctx))
        {
            s.warmfix_attempted = true;
            warmfix.takeover(&fw_access);
            _ = firmware.load(&fw_access, .force);
            if (!warmfix.phySoftReset(&fw_access)) {
                ctx.logWarn("RTL8168.R4D warmfix phy reset FAILED");
            }
            s.warmfix_active = true;
        }
    }
    if (!resetControllerBounded(&ctx)) {
        s.active = false;
        return false;
    }
    s.hard_resets +%= 1;
    if (s.warmfix_active) {
        if (!warmfix.applyStartChain(&fw_access)) {
            ctx.logWarn("RTL8168.R4D warmfix start-chain FAILED");
        }
    }
    if (!initializeHardware(&ctx, true)) {
        s.active = false;
        return false;
    }
    if (s.irq_registered) mmioWrite16(REG_INTERRUPT_MASK, interruptEventMask());
    if (cause_syserr) {
        s.syserr_recoveries +%= 1;
    } else {
        s.stall_recoveries +%= 1;
    }
    logRecoveryTelemetry(&ctx, cause_syserr);
    return true;
}

fn logRecoveryTelemetry(ctx: *const r4os.r4dev.DriverContext, cause_syserr: bool) void {
    // Recovery ist Ausnahmeverhalten; jede Ausfuehrung wird mit Ursache und
    // Gesamtzaehlern sichtbar (COM1/Bootlog/LOGSVC).
    var buf: [96]u8 = .{0} ** 96;
    var len: usize = 0;
    const prefix = if (cause_syserr)
        "RTL8168.R4D recovery cause=syserr"
    else
        "RTL8168.R4D recovery cause=tx-stall";
    for (prefix) |c| {
        buf[len] = c;
        len += 1;
    }
    len = appendCounter(&buf, len, " stall=", state.stall_recoveries);
    len = appendCounter(&buf, len, " syserr=", state.syserr_recoveries);
    len = appendCounter(&buf, len, " pcs=", state.pcs_timeout_events);
    ctx.logWarn(buf[0..len :0].ptr);
}

fn appendCounter(buf: *[96]u8, start: usize, label: []const u8, value: u64) usize {
    var len = start;
    if (len + label.len + 20 >= buf.len) return len;
    for (label) |c| {
        buf[len] = c;
        len += 1;
    }
    var digits: [20]u8 = undefined;
    var digit_count: usize = 0;
    var remaining = value;
    while (true) {
        digits[digit_count] = '0' + @as(u8, @intCast(remaining % 10));
        digit_count += 1;
        remaining /= 10;
        if (remaining == 0) break;
    }
    while (digit_count > 0) {
        digit_count -= 1;
        buf[len] = digits[digit_count];
        len += 1;
    }
    return len;
}

fn drainRx(s: *State) void {
    var drained: usize = 0;
    while (drained < RX_DRAIN_BUDGET) : (drained += 1) {
        if (@atomicLoad(bool, &s.recovery_pending, .acquire) or @atomicLoad(bool, &s.recovery_active, .acquire)) break;
        const slot = s.rx_head;
        const descriptor = rxDescriptor(slot);
        const opts1 = descriptor.opts1;
        if ((opts1 & contract.descriptor_owned) != 0) break;
        memoryFence();
        if (@atomicLoad(bool, &s.recovery_pending, .acquire)) break;

        if (contract.rxFrameLength(opts1, DMA_BUFFER_BYTES)) |frame_len| {
            const frame = rxBuffer(slot);
            if (context().netReceiveFrame(s.adapter_index, frame[0..frame_len]) == 0) {
                s.rx_ok +%= 1;
                if (!s.rx_confirmed) {
                    s.rx_confirmed = true;
                    const ctx = context();
                    logRxConfirmed(&ctx);
                }
            } else {
                s.rx_drops +%= 1;
            }
        } else {
            s.rx_errors +%= 1;
            s.rx_drops +%= 1;
        }

        descriptor.opts2 = 0;
        descriptor.addr = s.dma.phys_addr + RX_BUFFERS_OFFSET + slot * DMA_BUFFER_BYTES;
        memoryFence();
        descriptor.opts1 = contract.rxOwnedOptions(DMA_BUFFER_BYTES, slot + 1 == RX_DESCRIPTOR_COUNT);
        s.rx_head = (slot + 1) % RX_DESCRIPTOR_COUNT;
    }
}

fn setupInterrupts(ctx: *const r4os.r4dev.DriverContext) void {
    state.irq_registered = false;
    state.irq_route_count = 0;
    state.irq_active_route = 0xFF;
    if (irqDisabled(ctx) or state.info.interrupt_pin == 0) {
        state.irq_mode = 2;
        mmioWrite16(REG_INTERRUPT_MASK, 0);
        ctx.logWarn("RTL8168.R4D polling fallback");
        return;
    }

    // MSI zuerst (upstream nutzt fuer die aktuellen Chips ebenfalls MSI).
    // Die INTx-GSIs sind ohne ACPI-_PRT nur geraten; auf dem realen Lenovo
    // kam darueber nie ein Interrupt an. Der Pollpfad bleibt Sicherheitsnetz.
    if (!msiDisabled(ctx) and ctx.supportsDriverApi(16, @sizeOf(r4os.abi.DriverApi))) {
        const msi_irq = ctx.pciEnableMsi(state.info);
        if (msi_irq >= 0 and msi_irq < 32) {
            const route: u8 = @intCast(msi_irq);
            if (ctx.irqRegister(route, irqHandler, @intFromPtr(&state), r4os.abi.irq_flag_msi) == 0) {
                state.irq_routes[0] = route;
                state.irq_route_count = 1;
                state.irq_registered = true;
                state.irq_mode = 3;
                mmioWrite16(REG_INTERRUPT_STATUS, 0xFFFF);
                mmioWrite16(REG_INTERRUPT_MASK, interruptEventMask());
                ctx.logInfo("RTL8168.R4D MSI registered");
                return;
            }
        }
        ctx.logWarn("RTL8168.R4D MSI unavailable; trying shared INTx");
    }

    if (state.info.interrupt_line != 0xFF) _ = registerIrqRoute(ctx, state.info.interrupt_line);
    var gsi: u8 = 16;
    while (gsi < 24) : (gsi += 1) _ = registerIrqRoute(ctx, gsi);

    if (state.irq_route_count == 0) {
        state.irq_mode = 2;
        mmioWrite16(REG_INTERRUPT_MASK, 0);
        ctx.logWarn("RTL8168.R4D INTx registration failed; polling fallback");
        return;
    }
    state.irq_registered = true;
    state.irq_mode = 1;
    mmioWrite16(REG_INTERRUPT_STATUS, 0xFFFF);
    mmioWrite16(REG_INTERRUPT_MASK, interruptEventMask());
    ctx.logInfo("RTL8168.R4D shared INTx registered");
}

fn msiDisabled(ctx: *const r4os.r4dev.DriverContext) bool {
    return optionDisabled(ctx, "msi");
}

fn fwMode(ctx: *const r4os.r4dev.DriverContext) firmware.Mode {
    const value = ctx.getOption("RTL8168", "fw");
    if (zEqIgnoreCase(value, "force")) return .force;
    if (zEqIgnoreCase(value, "on") or zEqIgnoreCase(value, "enabled") or zEqIgnoreCase(value, "1")) return .on;
    return .off;
}

// Der Bridge-Check am Bind ist Standardverhalten; die Option steuert nur
// noch die stall-getriggerte Referenz-Eskalation (Takeover+Firmware+
// Startkette) als Sicherheitsnetz fuer unbekannte Warmzustaende.
fn warmfixEnabled(ctx: *const r4os.r4dev.DriverContext) bool {
    const value = ctx.getOption("RTL8168", "warmfix");
    return zEqIgnoreCase(value, "on") or zEqIgnoreCase(value, "enabled") or zEqIgnoreCase(value, "1");
}

// Warmfix-PCI-Leithypothese: Nach einem ACPI-Warmreset kann der Root-Port
// ueber der NIC sein Bus-Master-Enable verlieren - dann blockt er exakt alle
// von der NIC initiierten Upstream-Zugriffe (TX-Deskriptor-Fetch, RX-DMA-
// Writes, MSI), waehrend MMIO normal funktioniert. Linux/Windows aktivieren
// beim Enable die gesamte Bridge-Kette.

// Findet den naechstgelegenen Parent-Root-Port ueber der NIC (Bridge, deren
// Secondary..Subordinate den NIC-Bus umfasst).
fn warmfixFindBridge(ctx: *const r4os.r4dev.DriverContext) ?r4os.abi.PciDeviceInfo {
    var bridge: ?r4os.abi.PciDeviceInfo = null;
    var bridge_secondary: u8 = 0;
    const count = ctx.pciDeviceCount();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        var candidate: r4os.abi.PciDeviceInfo = .{};
        if (ctx.pciDeviceAt(index, &candidate) != 0) continue;
        if (candidate.bus_kind != state.info.bus_kind) continue;
        if (candidate.class_code != 0x06 or candidate.subclass != 0x04) continue;
        const buses = ctx.pciReadConfig32(candidate, 0x18);
        if (buses == 0xFFFF_FFFF) continue;
        const secondary: u8 = @truncate(buses >> 8);
        const subordinate: u8 = @truncate(buses >> 16);
        if (state.info.bus < secondary or state.info.bus > subordinate) continue;
        if (bridge == null or secondary >= bridge_secondary) {
            bridge = candidate;
            bridge_secondary = secondary;
        }
    }
    return bridge;
}

// Bind-zeitige Diagnose und Reparatur nach Linux pci_enable_bridge-
// Semantik (Standardverhalten seit dem realen 0.59.24-Durchbruch):
// Endpoint- und Bridge-COMMAND als Beweisspur loggen; fehlt der Bridge
// Memory-Space oder Bus-Master, werden beide gesetzt und verifiziert -
// auf gesunden Kaltboots ein reiner No-Op. Laeuft AUSSCHLIESSLICH im
// Init-Kontext, bevor Ringe oder Engines existieren.
fn warmfixBridgeAtBind(ctx: *const r4os.r4dev.DriverContext) void {
    const endpoint_command = ctx.pciReadConfig32(state.info, PCI_COMMAND_OFFSET);
    const bridge = warmfixFindBridge(ctx);

    var buf: [96]u8 = .{0} ** 96;
    var len: usize = 0;
    for ("RTL8168.R4D warmfix pci endpoint=0x") |c| {
        buf[len] = c;
        len += 1;
    }
    len = appendHex16(&buf, len, @truncate(endpoint_command & 0xFFFF));

    if (bridge) |parent| {
        const before = ctx.pciReadConfig32(parent, PCI_COMMAND_OFFSET);
        len = appendLabel(&buf, len, " bridge=0x");
        len = appendHex16(&buf, len, @truncate(before & 0xFFFF));
        const required = PCI_COMMAND_MEMORY_SPACE | PCI_COMMAND_BUS_MASTER;
        if (before != 0xFFFF_FFFF and (before & required) != required) {
            // Nur die unteren 16 Bits schreiben; ein 32-Bit-Echo wuerde
            // W1C-Statusbits loeschen.
            const requested: u16 = @as(u16, @truncate(before & 0xFFFF)) |
                @as(u16, @truncate(required));
            _ = ctx.pciWriteConfig32(parent, PCI_COMMAND_OFFSET, @as(u32, requested));
            const verified = ctx.pciReadConfig32(parent, PCI_COMMAND_OFFSET);
            len = appendLabel(&buf, len, " -> 0x");
            len = appendHex16(&buf, len, @truncate(verified & 0xFFFF));
        }
    } else {
        len = appendLabel(&buf, len, " bridge=none");
    }
    ctx.logWarn(buf[0..len :0].ptr);
}

fn appendLabel(buf: *[96]u8, start: usize, label: []const u8) usize {
    var len = start;
    if (len + label.len >= buf.len) return len;
    for (label) |c| {
        buf[len] = c;
        len += 1;
    }
    return len;
}

fn appendHex16(buf: *[96]u8, start: usize, value: u16) usize {
    const len = start;
    if (len + 4 >= buf.len) return len;
    const digits = "0123456789ABCDEF";
    buf[len] = digits[(value >> 12) & 0xF];
    buf[len + 1] = digits[(value >> 8) & 0xF];
    buf[len + 2] = digits[(value >> 4) & 0xF];
    buf[len + 3] = digits[value & 0xF];
    return len + 4;
}

// Firmware-Lader und Warmfix-Eskalation erhalten ausschliesslich diese
// Primitiven; alle indirekten Registerzugriffe leben in
// rtl8168_firmware.zig und rtl8168_warmfix.zig.
fn fwRead8(offset: u64) u8 {
    return mmioRead8(offset);
}

fn fwWrite8(offset: u64, value: u8) void {
    mmioWrite8(offset, value);
}

fn fwRead32(offset: u64) u32 {
    return mmioRead32(offset);
}

fn fwWrite32(offset: u64, value: u32) void {
    mmioWrite32(offset, value);
}

fn fwWaitMilliseconds(milliseconds: u32) void {
    const ctx = context();
    waitMilliseconds(&ctx, milliseconds);
}

fn fwLogInfo(text: [*:0]const u8) void {
    const ctx = context();
    ctx.logInfo(text);
}

fn fwLogWarn(text: [*:0]const u8) void {
    const ctx = context();
    ctx.logWarn(text);
}

const fw_access = firmware.Access{
    .read8 = fwRead8,
    .write8 = fwWrite8,
    .read32 = fwRead32,
    .write32 = fwWrite32,
    .waitMilliseconds = fwWaitMilliseconds,
    .logInfo = fwLogInfo,
    .logWarn = fwLogWarn,
};

fn optionDisabled(ctx: *const r4os.r4dev.DriverContext, key: [*:0]const u8) bool {
    const value = ctx.getOption("RTL8168", key);
    return zEqIgnoreCase(value, "off") or zEqIgnoreCase(value, "disabled") or zEqIgnoreCase(value, "0");
}

fn registerIrqRoute(ctx: *const r4os.r4dev.DriverContext, route: u8) bool {
    if (route >= 32 or state.irq_route_count >= state.irq_routes.len) return false;
    var index: usize = 0;
    while (index < state.irq_route_count) : (index += 1) {
        if (state.irq_routes[index] == route) return true;
    }
    const result = ctx.irqRegister(route, irqHandler, @intFromPtr(&state), r4os.abi.irq_flag_shared | r4os.abi.irq_flag_level_low);
    if (result != 0) return false;
    state.irq_routes[state.irq_route_count] = route;
    state.irq_route_count += 1;
    return true;
}

fn irqHandler(irq: u8, raw_context: usize) callconv(.c) u32 {
    const s: *State = @ptrFromInt(raw_context);
    if (!s.active or s.mmio.virt_addr == 0) return 0;
    const isr = mmioRead16(REG_INTERRUPT_STATUS);
    if (isr == 0 or isr == 0xFFFF or (isr & interruptEventMask()) == 0) {
        s.irq_unhandled +%= 1;
        return 0;
    }
    s.irq_count +%= 1;
    s.irq_active_route = irq;
    recordAndAckInterrupt(s, isr, true);
    s.poll_hint = true;
    s.irq_handled +%= 1;
    return r4os.abi.irq_result_handled;
}

fn recordAndAckInterrupt(s: *State, raw_isr: u16, from_irq: bool) void {
    s.last_isr = raw_isr;
    if ((raw_isr & INTERRUPT_RX_ERROR) != 0) s.rx_errors +%= 1;
    if ((raw_isr & INTERRUPT_TX_ERROR) != 0) s.tx_errors +%= 1;
    if ((raw_isr & (INTERRUPT_RX_OVERFLOW | INTERRUPT_RX_FIFO_OVERFLOW)) != 0) s.rx_overflows +%= 1;
    // Nur ein echter PCI-Systemfehler rechtfertigt einen Controllerreset
    // (upstream rtl8169_pcierr_interrupt). PCSTimeout wird ausschliesslich
    // gezaehlt; als Recovery-Ausloeser hat es auf dem realen GU wiederholte
    // unnoetige Vollresets erzeugt.
    if ((raw_isr & INTERRUPT_PCS_TIMEOUT) != 0) s.pcs_timeout_events +%= 1;
    if ((raw_isr & INTERRUPT_SYSTEM_ERROR) != 0) {
        s.syserr_events +%= 1;
        @atomicStore(bool, &s.recovery_cause_syserr, true, .release);
        @atomicStore(bool, &s.recovery_pending, true, .release);
    }
    if (!from_irq and (raw_isr & interruptEventMask()) != 0) s.poll_hint = true;
    // Alle gelesenen Statusbits quittieren (W1C), damit nicht maskierte
    // Ereignisse wie PCSTimeout nicht dauerhaft gelatcht bleiben.
    mmioWrite16(REG_INTERRUPT_STATUS, raw_isr);
}

fn irqDisabled(ctx: *const r4os.r4dev.DriverContext) bool {
    const value = ctx.getOption("RTL8168", "irq");
    return zEqIgnoreCase(value, "off") or zEqIgnoreCase(value, "disabled") or zEqIgnoreCase(value, "0");
}

fn backendShutdown(raw_context: ?*anyopaque) callconv(.c) i32 {
    _ = raw_context;
    // Normal R4D unload calls the top-level shutdown first and the backend
    // finalizer during owner cleanup. Do not touch a controller twice after
    // the transition shutdown has already established its handoff state.
    if (!state.registered) return 0;
    var ctx = context();
    shutdownHardware(&ctx);
    return 0;
}

fn status(raw_context: ?*anyopaque, out: *r4os.abi.NetBackendStatus) callconv(.c) i32 {
    const s = stateFrom(raw_context) orelse return -1;
    out.* = .{
        .link_up = if (s.active and linkUp()) 1 else 0,
        .rx_packets = s.rx_ok,
        .tx_packets = s.tx_ok,
        .drops = s.rx_drops,
        .errors = s.rx_errors + s.tx_errors + s.rx_overflows,
        .irq_line = irqDisplayLine(s),
        .irq_pin = s.info.interrupt_pin,
        .irq_registered = if (s.irq_registered) 1 else 0,
        .irq_mode = s.irq_mode,
        .irq_count = s.irq_count,
        .irq_handled = s.irq_handled,
        .poll_count = s.poll_count,
        .poll_fallbacks = s.poll_fallbacks,
        .last_isr = s.last_isr,
        .reserved = s.xid,
        .rx_errors = s.rx_errors,
        .tx_errors = s.tx_errors,
        .rx_overflows = s.rx_overflows,
        .rx_recoveries = s.tx_stuck_recoveries,
    };
    return 0;
}

fn shutdownHardware(ctx: *const r4os.r4dev.DriverContext) void {
    _ = shutdownHardwareInternal(ctx, false);
}

fn shutdownHardwareForTransition(ctx: *const r4os.r4dev.DriverContext) bool {
    return shutdownHardwareInternal(ctx, true);
}

fn shutdownHardwareInternal(ctx: *const r4os.r4dev.DriverContext, transition: bool) bool {
    state.active = false;
    // No new poll or transmit can enter after active=false. Wait for work that
    // passed the old active check before touching its descriptor memory.
    const software_idle = waitForSoftwareIdle(ctx);
    if (!software_idle) ctx.logWarn("RTL8168.R4D shutdown software-idle timeout");

    var bus_master_disabled = !state.pci_device_found;
    // PCI Command safety is independent of a mapped BAR. Init can fail before
    // MMIO exists; prove the bus-master readback here or veto owner cleanup.
    if (state.pci_device_found) {
        bus_master_disabled = disablePciBusMaster(ctx);
        if (!bus_master_disabled) ctx.logWarn("RTL8168.R4D shutdown bus-master disable failed");
    }
    if (state.mmio.virt_addr != 0) {
        // Stop new DMA first and commit that PCI command transition before
        // quiescing the MAC. This prevents an old ring fetch from crossing
        // the ACPI reset boundary. Der Stopp bleibt bewusst reset-frei wie
        // der Bind; ein CmdReset gehoert nicht in den Uebergabepfad.
        pciCommit();
        mmioWrite16(REG_INTERRUPT_MASK, 0);
        mmioWrite16(REG_INTERRUPT_STATUS, 0xFFFF);
        pciCommit();

        const rx_config = mmioRead32(REG_RX_CONFIG);
        mmioWrite32(REG_RX_CONFIG, rx_config & ~@as(u32, RX_CONFIG_ACCEPT_MASK));
        mmioWrite8(REG_CHIP_COMMAND, 0);
        pciCommit();
        waitMilliseconds(ctx, 1);
        mmioWrite16(REG_INTERRUPT_MASK, 0);
        mmioWrite16(REG_INTERRUPT_STATUS, 0xFFFF);
    }
    if (state.irq_registered) {
        var index: usize = 0;
        while (index < state.irq_route_count) : (index += 1) {
            _ = ctx.irqUnregister(state.irq_routes[index], irqHandler, @intFromPtr(&state));
        }
    }
    state.irq_registered = false;
    state.irq_route_count = 0;
    // A system-transition shutdown deliberately leaves the old DMA pages
    // owned until reset. Normal backend cleanup and init-failure cleanup
    // still release their region here; a regular R4D unload releases
    // transition-held DMA through commitOwnerCleanup.
    if (state.dma.phys_addr != 0 and !transition and software_idle and bus_master_disabled) {
        ctx.freeDmaRegion(&state.dma);
    }
    state.registered = false;
    return software_idle and bus_master_disabled;
}

fn waitForSoftwareIdle(ctx: *const r4os.r4dev.DriverContext) bool {
    const timeout = contract.ticksForMilliseconds(ctx.timerFrequency(), SHUTDOWN_SOFTWARE_IDLE_MILLISECONDS);
    const start = ctx.tickCount();
    while (@atomicLoad(bool, &state.poll_active, .acquire) or
        @atomicLoad(bool, &state.tx_lock, .acquire) or
        @atomicLoad(bool, &state.recovery_active, .acquire))
    {
        if (ctx.tickCount() -% start >= timeout) return false;
        ctx.waitTicks(1);
    }
    return true;
}

fn disablePciBusMaster(ctx: *const r4os.r4dev.DriverContext) bool {
    const raw = ctx.pciReadConfig32(state.info, PCI_COMMAND_OFFSET);
    if (raw == 0xFFFF_FFFF) return false;
    if ((raw & PCI_COMMAND_BUS_MASTER) == 0) return true;
    if (ctx.pciWriteConfig32(state.info, PCI_COMMAND_OFFSET, contract.pciCommandWithoutBusMaster(raw)) != 0) return false;
    const verified = ctx.pciReadConfig32(state.info, PCI_COMMAND_OFFSET);
    return verified != 0xFFFF_FFFF and (verified & PCI_COMMAND_BUS_MASTER) == 0;
}

fn restoreMacAddress() void {
    mmioWrite8(REG_CFG9346, CFG9346_UNLOCK);
    defer mmioWrite8(REG_CFG9346, CFG9346_LOCK);

    // Linux r8169 programs the receive-address high dword before the low
    // dword after ChipCmd reset. Preserve that order so a reset can never
    // leave the next driver instance with a transient or cleared address.
    mmioWrite32(REG_MAC4, contract.macAddressHigh(state.mac));
    _ = mmioRead8(REG_CHIP_COMMAND);
    mmioWrite32(REG_MAC0, contract.macAddressLow(state.mac));
    _ = mmioRead8(REG_CHIP_COMMAND);
}

fn resetControllerBounded(ctx: *const r4os.r4dev.DriverContext) bool {
    // Einziger CmdReset-Aufrufer: die Stall-/SYSErr-Recovery zur Laufzeit.
    // Der Bind und der Shutdown bleiben reset-frei.
    memoryFence();
    mmioWrite8(REG_CHIP_COMMAND, CHIP_COMMAND_RESET);
    const timeout = contract.ticksForMilliseconds(ctx.timerFrequency(), CONTROLLER_RESET_MILLISECONDS);
    const start = ctx.tickCount();
    while ((mmioRead8(REG_CHIP_COMMAND) & CHIP_COMMAND_RESET) != 0) {
        if (ctx.tickCount() -% start >= timeout) return false;
        ctx.waitTicks(1);
    }
    waitMilliseconds(ctx, 1);
    restoreMacAddress();
    return true;
}

fn waitMilliseconds(ctx: *const r4os.r4dev.DriverContext, milliseconds: u32) void {
    const ticks = contract.ticksForMilliseconds(ctx.timerFrequency(), milliseconds);
    if (ticks != 0) ctx.waitTicks(ticks);
}

fn linkUp() bool {
    return state.mmio.virt_addr != 0 and (mmioRead8(REG_PHY_STATUS) & PHY_STATUS_LINK) != 0;
}

fn readMac() void {
    var index: usize = 0;
    while (index < state.mac.len) : (index += 1) state.mac[index] = mmioRead8(REG_MAC0 + index);
}

fn validMac(mac: [6]u8) bool {
    if ((mac[0] & 1) != 0) return false;
    var any_nonzero = false;
    var any_not_ff = false;
    for (mac) |byte| {
        if (byte != 0) any_nonzero = true;
        if (byte != 0xFF) any_not_ff = true;
    }
    return any_nonzero and any_not_ff;
}

fn irqDisplayLine(s: *const State) u8 {
    if (s.irq_active_route != 0xFF) return s.irq_active_route;
    if (s.irq_route_count > 0) return s.irq_routes[0];
    return s.info.interrupt_line;
}

fn stateFrom(raw_context: ?*anyopaque) ?*State {
    const raw = raw_context orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn txDescriptor(index: usize) *volatile contract.Descriptor {
    return @ptrFromInt(state.dma.virt_addr + TX_RING_OFFSET + index * @sizeOf(contract.Descriptor));
}

fn rxDescriptor(index: usize) *volatile contract.Descriptor {
    return @ptrFromInt(state.dma.virt_addr + RX_RING_OFFSET + index * @sizeOf(contract.Descriptor));
}

fn txBuffer(index: usize) []u8 {
    const ptr: [*]u8 = @ptrFromInt(state.dma.virt_addr + TX_BUFFERS_OFFSET + index * DMA_BUFFER_BYTES);
    return ptr[0..DMA_BUFFER_BYTES];
}

fn rxBuffer(index: usize) []u8 {
    const ptr: [*]u8 = @ptrFromInt(state.dma.virt_addr + RX_BUFFERS_OFFSET + index * DMA_BUFFER_BYTES);
    return ptr[0..DMA_BUFFER_BYTES];
}

fn mmioRead8(offset: u64) u8 {
    if (builtin.is_test) {
        if (test_mmio_hooks) |hooks| return hooks.read8(offset);
    }
    const ptr: *volatile u8 = @ptrFromInt(state.mmio.virt_addr + offset);
    return ptr.*;
}

fn mmioRead16(offset: u64) u16 {
    if (builtin.is_test) {
        if (test_mmio_hooks) |hooks| return hooks.read16(offset);
    }
    const ptr: *volatile u16 = @ptrFromInt(state.mmio.virt_addr + offset);
    return ptr.*;
}

fn mmioRead32(offset: u64) u32 {
    if (builtin.is_test) {
        if (test_mmio_hooks) |hooks| return hooks.read32(offset);
    }
    const ptr: *volatile u32 = @ptrFromInt(state.mmio.virt_addr + offset);
    return ptr.*;
}

fn mmioWrite8(offset: u64, value: u8) void {
    if (builtin.is_test) {
        if (test_mmio_hooks) |hooks| return hooks.write8(offset, value);
    }
    const ptr: *volatile u8 = @ptrFromInt(state.mmio.virt_addr + offset);
    ptr.* = value;
}

fn mmioWrite16(offset: u64, value: u16) void {
    if (builtin.is_test) {
        if (test_mmio_hooks) |hooks| return hooks.write16(offset, value);
    }
    const ptr: *volatile u16 = @ptrFromInt(state.mmio.virt_addr + offset);
    ptr.* = value;
}

fn mmioWrite32(offset: u64, value: u32) void {
    if (builtin.is_test) {
        if (test_mmio_hooks) |hooks| return hooks.write32(offset, value);
    }
    const ptr: *volatile u32 = @ptrFromInt(state.mmio.virt_addr + offset);
    ptr.* = value;
}

fn pciCommit() void {
    memoryFence();
    _ = mmioRead8(REG_CHIP_COMMAND);
}

fn memoryFence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn cpuRelax() void {
    asm volatile ("pause" ::: .{ .memory = true });
}

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn zEqIgnoreCase(value: [*:0]const u8, text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const c = value[index];
        if (c == 0 or upper(c) != upper(text[index])) return false;
    }
    return value[text.len] == 0;
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - ('a' - 'A') else c;
}
