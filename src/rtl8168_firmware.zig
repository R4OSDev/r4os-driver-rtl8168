// RTL8168GU-Firmware-Ladepfad (0.59.22).
//
// Dieser Baustein ist der EINZIGE Ort im Treiber, der indirekte
// MAC-OCP-/GPHY-OCP-Registerzugriffe ausfuehren darf. Er laeuft
// ausschliesslich hinter `OPTION RTL8168 fw=on|force` (Default aus) und
// nur fuer die exakte GU-Identitaet XID 0x509 (vendor CFG_METHOD_25).
// Der reset-freie Legacy-Bind in main.zig bleibt unveraendert.
//
// Quelle der Sequenzen: GPL-Vendortreiber r8168_n.c (Reference/),
// Analyse und Vertrag: Docs/Drivers/Rtl8168FirmwarePfad05921.txt.
//
// MAC-MCU-Vertrag (unteilbar): Breakpoints 0xFC28..0xFC36 = 0, 3 ms,
// 0xFC26 = 0, dann der komplette Patch inklusive Aktivierung
// (0xFC26 = 0x8000) und Breakpoint-Werten in Tabellenreihenfolge.
// Der Zustand nach dem Disable OHNE Patch ist der real bewiesene
// Kaltpfad-Killer; ein Einstieg ohne Abschluss ist verboten.
//
// PHY-Vertrag: Versionsmarker 0x801E gegen 0x0001 (Skip wenn aktuell,
// ausser fw=force), Patch-Request-Handshake (Seite 0x0B82 Reg 0x10
// Bit 4, Warten auf Seite 0x0B80 Reg 0x10 Bit 6), RAM-Code-Ops,
// Handshake loesen, Versionsmarker schreiben.

const tables = @import("rtl8168_firmware_tables.zig");

pub const Mode = enum { off, on, force };
pub const Result = enum { loaded, phy_skipped_current, failed };

pub const Access = struct {
    read8: *const fn (u64) u8,
    write8: *const fn (u64, u8) void,
    read32: *const fn (u64) u32,
    write32: *const fn (u64, u32) void,
    waitMilliseconds: *const fn (u32) void,
    logInfo: *const fn ([*:0]const u8) void,
    logWarn: *const fn ([*:0]const u8) void,
};

const REG_MAC_OCP: u64 = 0xB0;
const REG_GPHY_OCP: u64 = 0xB8;
const GPHY_OCP_WRITE: u32 = 1 << 31;
const GPHY_OCP_FLAG: u32 = 1 << 31;
const OCP_STD_PHY_BASE: u16 = 0xA400;
// NIC_RAMCODE_VERSION_CFG_METHOD_24 (gilt fuer CFG_METHOD_24/25).
const RAM_CODE_VERSION: u16 = 0x0001;
const PHY_VERSION_PARAMETER: u16 = 0x801E;
const MCU_BPS_SETTLE_MILLISECONDS: u32 = 3;
const HANDSHAKE_ATTEMPTS: u32 = 200;
const GPHY_SPINS: usize = 1000;
const GPHY_RETRIES: usize = 40;

pub fn load(a: *const Access, mode: Mode) Result {
    loadMacMcu(a);
    return loadPhyRamCode(a, mode);
}

// --- MAC-MCU ---------------------------------------------------------------

fn loadMacMcu(a: *const Access) void {
    // Schritt 1: Breakpoints und Patch-Basis stilllegen (Vendor
    // hw_disable_mac_mcu_bps). Ab hier ist der Vertrag unteilbar.
    const breakpoint_registers = [_]u16{ 0xFC28, 0xFC2A, 0xFC2C, 0xFC2E, 0xFC30, 0xFC32, 0xFC34, 0xFC36 };
    for (breakpoint_registers) |register| macOcpWrite(a, register, 0x0000);
    a.waitMilliseconds(MCU_BPS_SETTLE_MILLISECONDS);
    macOcpWrite(a, 0xFC26, 0x0000);

    // Schritte 2+3: Patchcode, Aktivierung (0xFC26=0x8000) und
    // Breakpoint-Werte in exakter Vendor-Reihenfolge aus der Tabelle.
    for (tables.mac_mcu_gu2) |entry| macOcpWrite(a, entry.addr, entry.value);
    a.logInfo("RTL8168.R4D fw mac-mcu loaded words=417");
}

fn macOcpWrite(a: *const Access, address: u16, value: u16) void {
    // Vendor-Semantik: posted 32-Bit-Write ohne Completion-Flag.
    a.write32(REG_MAC_OCP, (@as(u32, 1) << 31) | (@as(u32, address >> 1) << 16) | value);
}

// --- PHY-RAM-Code ----------------------------------------------------------

fn loadPhyRamCode(a: *const Access, mode: Mode) Result {
    const current = readPhyParameter(a, PHY_VERSION_PARAMETER) orelse {
        a.logWarn("RTL8168.R4D fw phy version read FAILED");
        return .failed;
    };
    if (current == RAM_CODE_VERSION and mode != .force) {
        a.logInfo("RTL8168.R4D fw phy ram-code current; skipped");
        return .phy_skipped_current;
    }

    if (!patchRequest(a, true)) {
        a.logWarn("RTL8168.R4D fw phy patch-request timeout; continuing");
    }

    var base: u16 = OCP_STD_PHY_BASE;
    var ok = true;
    for (tables.phy_ram_code_gu2) |op| {
        switch (op.kind) {
            .page => base = pageBase(op.value),
            .addr => ok = phyWriteReg(a, base, 0x13, op.value) and ok,
            .data => ok = phyWriteReg(a, base, 0x14, op.value) and ok,
            .rmw17_clear_bit0 => {
                if (phyReadReg(a, base, 0x17)) |value| {
                    ok = phyWriteReg(a, base, 0x17, value & ~@as(u16, 1)) and ok;
                } else {
                    ok = false;
                }
            },
        }
    }

    if (!patchRequest(a, false)) {
        a.logWarn("RTL8168.R4D fw phy patch-release timeout; continuing");
    }

    if (!ok) {
        // Kein Versionsmarker auf einen unvollstaendigen Stand schreiben:
        // der naechste Ladeversuch darf nicht als "aktuell" uebersprungen
        // werden.
        a.logWarn("RTL8168.R4D fw phy ram-code write FAILED");
        return .failed;
    }
    if (!writePhyParameter(a, PHY_VERSION_PARAMETER, RAM_CODE_VERSION)) {
        a.logWarn("RTL8168.R4D fw phy version write FAILED");
        return .failed;
    }
    a.logInfo("RTL8168.R4D fw phy ram-code loaded ops=38");
    return .loaded;
}

fn pageBase(page: u16) u16 {
    return if (page == 0) OCP_STD_PHY_BASE else page << 4;
}

fn phyRegisterAddress(base: u16, register: u16) u16 {
    // r8168g-MDIO-Modell: Standardseite adressiert Reg*2 ab 0xA400,
    // alle anderen Seiten adressieren (Reg-0x10)*2 ab Seitenbasis.
    return if (base == OCP_STD_PHY_BASE)
        base +% register *% 2
    else
        base +% (register -% 0x10) *% 2;
}

fn phyReadReg(a: *const Access, base: u16, register: u16) ?u16 {
    return gphyOcpReadAddress(a, phyRegisterAddress(base, register));
}

fn phyWriteReg(a: *const Access, base: u16, register: u16, value: u16) bool {
    return gphyOcpWriteAddress(a, phyRegisterAddress(base, register), value);
}

fn readPhyParameter(a: *const Access, parameter: u16) ?u16 {
    const base = pageBase(0x0A43);
    if (!phyWriteReg(a, base, 0x13, parameter)) return null;
    return phyReadReg(a, base, 0x14);
}

fn writePhyParameter(a: *const Access, parameter: u16, value: u16) bool {
    const base = pageBase(0x0A43);
    if (!phyWriteReg(a, base, 0x13, parameter)) return false;
    return phyWriteReg(a, base, 0x14, value);
}

fn patchRequest(a: *const Access, request: bool) bool {
    // Seite 0x0B82 Reg 0x10 Bit 4 setzen/loeschen, dann Seite 0x0B80
    // Reg 0x10 Bit 6 auf den Zielzustand abwarten (Vendor: 100 ms Budget).
    const control_base = pageBase(0x0B82);
    const status_base = pageBase(0x0B80);
    const control = phyReadReg(a, control_base, 0x10) orelse return false;
    const requested: u16 = if (request) control | (1 << 4) else control & ~@as(u16, 1 << 4);
    if (!phyWriteReg(a, control_base, 0x10, requested)) return false;

    var attempt: u32 = 0;
    while (attempt < HANDSHAKE_ATTEMPTS) : (attempt += 1) {
        if (phyReadReg(a, status_base, 0x10)) |status| {
            const ready = (status & (1 << 6)) != 0;
            if (ready == request) return true;
        }
        a.waitMilliseconds(1);
    }
    return false;
}

// --- Gebundene GPHY-OCP-Rohzugriffe (auch vom Warmfix-Modul genutzt) -------

pub fn gphyOcpReadAddress(a: *const Access, address: u16) ?u16 {
    a.write32(REG_GPHY_OCP, @as(u32, address) << 15);
    var retry: usize = 0;
    while (retry < GPHY_RETRIES) : (retry += 1) {
        var spin: usize = 0;
        while (spin < GPHY_SPINS) : (spin += 1) {
            const value = a.read32(REG_GPHY_OCP);
            if ((value & GPHY_OCP_FLAG) != 0) return @truncate(value);
        }
        a.waitMilliseconds(1);
    }
    return null;
}

pub fn gphyOcpWriteAddress(a: *const Access, address: u16, value: u16) bool {
    a.write32(REG_GPHY_OCP, GPHY_OCP_WRITE | (@as(u32, address) << 15) | value);
    var retry: usize = 0;
    while (retry < GPHY_RETRIES) : (retry += 1) {
        var spin: usize = 0;
        while (spin < GPHY_SPINS) : (spin += 1) {
            if ((a.read32(REG_GPHY_OCP) & GPHY_OCP_FLAG) == 0) return true;
        }
        a.waitMilliseconds(1);
    }
    return false;
}
