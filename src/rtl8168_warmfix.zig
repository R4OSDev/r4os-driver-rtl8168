// RTL8168GU-Warmfix-Eskalation (0.59.24).
//
// Der 0.59.23-Praezisionsbefund: Nach einem ACPI-Warmreset ist der PHY
// funktional (Link kommt, Firmware laedt, OCP antwortet), aber die
// MAC-seitige TX-/DMA-Engine holt keine Deskriptoren ab. Handoff ohne
// Firmware (WARM.TXT-Aera) und Firmware ohne Handoff (0.59.23) heilen
// das nicht; Linux/Windows fahren BEIDES plus die volle Startkette.
//
// Dieses Modul traegt die fehlenden Referenzschritte - ausgefuehrt
// NIEMALS beim Bind, sondern ausschliesslich als einmalige
// Recovery-Eskalation nach mehreren echten TX-Stalls (ein Zustand, den
// reale Kaltboots nie erreichen) und nur hinter
// `OPTION RTL8168 warmfix=on`. Der reset-freie Kaltbind bleibt
// byteidentisch.
//
// Referenz: upstream rtl_hw_init_8168g (Ownership-Handoff) und
// rtl_hw_start_8168g/_2 (ERI-FIFO-Schwellen, EPHY e_info_8168g_2,
// TXCFG_AUTO_FIFO, EarlySize 0x27, VER_40-RxConfig). BEWUSST NICHT
// enthalten: EEE (real bewiesener RX-Killer), RealWoW, Exit-L1.

const contract = @import("rtl8168_contract.zig");
const firmware = @import("rtl8168_firmware.zig");

pub const Access = firmware.Access;

const REG_CHIP_COMMAND: u64 = 0x37;
const REG_TX_CONFIG: u64 = 0x40;
const REG_ERI_DATA: u64 = 0x70;
const REG_ERI_ACCESS: u64 = 0x74;
const REG_EPHY_ACCESS: u64 = 0x80;
const REG_MAC_OCP: u64 = 0xB0;
const REG_MCU: u64 = 0xD3;
const REG_MISC: u64 = 0xF0;

const CHIP_RX_ENABLE: u8 = 0x08;
const CHIP_TX_ENABLE: u8 = 0x04;
const MISC_RXDV_GATED: u32 = 1 << 19;
const TXCFG_FIFO_EMPTY: u32 = 1 << 11;
const MCU_RXTX_EMPTY: u8 = (1 << 5) | (1 << 4);
const MCU_NOW_IS_OOB_BIT: u8 = 1 << 7;
const MCU_LINK_LIST_READY_BIT: u8 = 1 << 1;
const ACCESS_FLAG: u32 = 1 << 31;
const BMCR_RESET_BIT: u16 = 1 << 15;

const FIFO_DRAIN_ATTEMPTS: u32 = 50;
const LINK_LIST_ATTEMPTS: u32 = 100;
const INDIRECT_SPINS: usize = 1000;
const INDIRECT_RETRIES: usize = 40;
const PHY_RESET_ATTEMPTS: u32 = 600;

// Referenz-Startwerte fuer den aktivierten Warmfix-Zustand
// (rtl_hw_start_8168g/_2 bzw. rtl_init_rxcfg fuer VER_40..53).
const TXCFG_INTERFRAME_GAP: u32 = 3 << 24;
const TXCFG_DMA_UNLIMITED: u32 = 7 << 8;
const TXCFG_AUTO_FIFO: u32 = 1 << 7;
const RXCFG_128_INT_EN: u32 = 1 << 15;
const RXCFG_MULTI_EN: u32 = 1 << 14;
const RXCFG_EARLY_OFF: u32 = 1 << 11;
const RXCFG_DMA_BURST: u32 = 7 << 8;
const RXCFG_ACCEPT_BROADCAST: u32 = 1 << 3;
const RXCFG_ACCEPT_MULTICAST: u32 = 1 << 2;
const RXCFG_ACCEPT_PHYSICAL: u32 = 1 << 1;

pub fn txConfigValue() u32 {
    return TXCFG_INTERFRAME_GAP | TXCFG_DMA_UNLIMITED | TXCFG_AUTO_FIFO;
}

pub fn earlyTxSize() u8 {
    return 0x27;
}

pub fn rxConfigValue() u32 {
    return RXCFG_128_INT_EN | RXCFG_MULTI_EN | RXCFG_EARLY_OFF | RXCFG_DMA_BURST |
        RXCFG_ACCEPT_BROADCAST | RXCFG_ACCEPT_MULTICAST | RXCFG_ACCEPT_PHYSICAL;
}

/// Ownership-Uebernahme nach upstream rtl_hw_init_8168g. Advisory-Timeouts
/// brechen die Uebernahme nicht ab (Fall-b-Sichtbarkeit); jede Stufe wird
/// zu Ende gefahren.
pub fn takeover(a: *const Access) void {
    a.write32(REG_MISC, a.read32(REG_MISC) | MISC_RXDV_GATED);
    a.waitMilliseconds(2);

    if (!waitFifoEmpty(a)) {
        a.logWarn("RTL8168.R4D warmfix fifo-drain timeout; continuing");
    }

    const chip = a.read8(REG_CHIP_COMMAND);
    a.write8(REG_CHIP_COMMAND, chip & ~@as(u8, CHIP_RX_ENABLE | CHIP_TX_ENABLE));

    const mcu = a.read8(REG_MCU);
    a.write8(REG_MCU, mcu & ~@as(u8, MCU_NOW_IS_OOB_BIT));

    if (!macOcpModify(a, 0xE8DE, 1 << 14, 0)) {
        a.logWarn("RTL8168.R4D warmfix e8de clear FAILED");
    }
    if (!waitLinkListReady(a)) {
        a.logWarn("RTL8168.R4D warmfix first link-list timeout; continuing");
    }
    if (!macOcpModify(a, 0xE8DE, 0, 1 << 15)) {
        a.logWarn("RTL8168.R4D warmfix e8de set FAILED");
    }
    if (!waitLinkListReady(a)) {
        a.logWarn("RTL8168.R4D warmfix second link-list timeout; continuing");
    }
    a.logInfo("RTL8168.R4D warmfix takeover applied");
}

/// PHY-Softreset (Linux phy_init_hw-Aequivalent): BMCR Bit 15 setzen und
/// den Selbstruecksetzer abwarten. Autoneg fordert der normale
/// Recovery-Reinit anschliessend ueber den Legacy-Pfad an.
pub fn phySoftReset(a: *const Access) bool {
    const bmcr = firmware.gphyOcpReadAddress(a, 0xA400) orelse return false;
    if (!firmware.gphyOcpWriteAddress(a, 0xA400, bmcr | BMCR_RESET_BIT)) return false;
    var attempt: u32 = 0;
    while (attempt < PHY_RESET_ATTEMPTS) : (attempt += 1) {
        const value = firmware.gphyOcpReadAddress(a, 0xA400) orelse return false;
        if ((value & BMCR_RESET_BIT) == 0) return true;
        a.waitMilliseconds(1);
    }
    return false;
}

/// Referenz-Startkette nach jedem Controllerreset im Warmfix-Zustand:
/// ERI-FIFO-Schwellen und die EPHY-Baseline e_info_8168g_2.
pub fn applyStartChain(a: *const Access) bool {
    var ok = true;
    ok = eriWrite(a, 0x00C8, 0xF, 0x0008_0002) and ok;
    ok = eriWrite(a, 0x00E8, 0xF, 0x0010_0006) and ok;
    ok = eriWrite(a, 0x00CC, 0x1, 0x0000_0038) and ok;
    ok = eriWrite(a, 0x00D0, 0x1, 0x0000_0048) and ok;

    for (contract.rtl8168g2_ephy_baseline) |patch| {
        const current = ephyRead(a, patch.register) orelse {
            ok = false;
            continue;
        };
        const value = (current & ~patch.clear_mask) | patch.set_bits;
        ok = ephyWrite(a, patch.register, value) and ok;
    }
    return ok;
}

// --- Advisory-Waits --------------------------------------------------------

fn waitFifoEmpty(a: *const Access) bool {
    var attempt: u32 = 0;
    while (attempt < FIFO_DRAIN_ATTEMPTS) : (attempt += 1) {
        const tx_empty = (a.read32(REG_TX_CONFIG) & TXCFG_FIFO_EMPTY) != 0;
        const mcu_empty = (a.read8(REG_MCU) & MCU_RXTX_EMPTY) == MCU_RXTX_EMPTY;
        if (tx_empty and mcu_empty) return true;
        a.waitMilliseconds(1);
    }
    return false;
}

fn waitLinkListReady(a: *const Access) bool {
    var attempt: u32 = 0;
    while (attempt < LINK_LIST_ATTEMPTS) : (attempt += 1) {
        if ((a.read8(REG_MCU) & MCU_LINK_LIST_READY_BIT) != 0) return true;
        a.waitMilliseconds(1);
    }
    return false;
}

// --- Indirekte Zugriffe ueber die Contract-Kommandobauer -------------------

fn macOcpRead(a: *const Access, register: u16) ?u16 {
    const command = contract.macOcpReadCommand(register) orelse return null;
    a.write32(REG_MAC_OCP, command);
    return @truncate(a.read32(REG_MAC_OCP) & 0xFFFF);
}

fn macOcpWrite(a: *const Access, register: u16, value: u16) bool {
    const command = contract.macOcpWriteCommand(register, value) orelse return false;
    a.write32(REG_MAC_OCP, command);
    return true;
}

fn macOcpModify(a: *const Access, register: u16, clear_mask: u16, set_bits: u16) bool {
    const current = macOcpRead(a, register) orelse return false;
    return macOcpWrite(a, register, (current & ~clear_mask) | set_bits);
}

fn eriWrite(a: *const Access, address: u16, byte_enable: u4, value: u32) bool {
    const command = contract.eriWriteCommand(address, byte_enable) orelse return false;
    a.write32(REG_ERI_DATA, value);
    a.write32(REG_ERI_ACCESS, command);
    return waitFlag32(a, REG_ERI_ACCESS, false);
}

fn ephyRead(a: *const Access, register: u5) ?u16 {
    a.write32(REG_EPHY_ACCESS, contract.ephyReadCommand(register));
    if (!waitFlag32(a, REG_EPHY_ACCESS, true)) return null;
    return @truncate(a.read32(REG_EPHY_ACCESS) & 0xFFFF);
}

fn ephyWrite(a: *const Access, register: u5, value: u16) bool {
    a.write32(REG_EPHY_ACCESS, contract.ephyWriteCommand(register, value));
    return waitFlag32(a, REG_EPHY_ACCESS, false);
}

fn waitFlag32(a: *const Access, offset: u64, expect_set: bool) bool {
    var retry: usize = 0;
    while (retry < INDIRECT_RETRIES) : (retry += 1) {
        var spin: usize = 0;
        while (spin < INDIRECT_SPINS) : (spin += 1) {
            const set = (a.read32(offset) & ACCESS_FLAG) != 0;
            if (set == expect_set) return true;
        }
        a.waitMilliseconds(1);
    }
    return false;
}
