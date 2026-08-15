param([string]$RepositoryRoot = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')) } else { $RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot) }

# Erzeugt Code/System/Driver/RTL8168/src/rtl8168_firmware_tables.zig
# mechanisch aus dem GPL-Vendortreiber (Reference). Einmal-Generator;
# die erzeugte Datei wird eingecheckt und vom 0595-Gate über Wortzahlen
# und Ankerwerte geprüft.

$sourcePath = Join-Path $RepositoryRoot 'Reference\Hardware\RTL8168\r8168-realtek-vendor\r8168_n.c'
$targetPath = Join-Path $RepositoryRoot 'Code\System\Driver\RTL8168\src\rtl8168_firmware_tables.zig'
$lines = Get-Content -LiteralPath $sourcePath

function Find-FunctionBody([string]$name) {
    $startIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^$name\(") { $startIdx = $i; break }
    }
    if ($startIdx -lt 0) { throw "Funktion nicht gefunden: $name" }
    $endIdx = -1
    for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\}') { $endIdx = $i; break }
    }
    if ($endIdx -lt 0) { throw "Funktionsende nicht gefunden: $name" }
    return $lines[$startIdx..$endIdx]
}

# --- MAC-MCU-Patch (rtl8168_set_mac_mcu_8168gu_2, CFG_METHOD_25) ---
$macBody = Find-FunctionBody 'rtl8168_set_mac_mcu_8168gu_2'
$macPairs = @()
foreach ($line in $macBody) {
    if ($line -match '^\s*rtl8168_mac_ocp_write\(tp,\s*(0x[0-9A-Fa-f]+),\s*(0x[0-9A-Fa-f]+)\);\s*$') {
        $macPairs += ,@([Convert]::ToUInt32($Matches[1], 16), [Convert]::ToUInt32($Matches[2], 16))
    } elseif ($line -match 'rtl8168_mac_ocp_write') {
        throw "Unerwartete MAC-OCP-Zeile: $line"
    }
}
if ($macPairs.Count -ne 417) { throw "MAC-MCU-Wortzahl unerwartet: $($macPairs.Count) statt 417" }
if ($macPairs[0][0] -ne 0xF800 -or $macPairs[0][1] -ne 0xE008) { throw 'MAC-MCU-Anfangsanker (0xF800=0xE008) verletzt.' }
$fc26 = @($macPairs | Where-Object { $_[0] -eq 0xFC26 })
if ($fc26.Count -ne 1 -or $fc26[0][1] -ne 0x8000) { throw 'MAC-MCU-Aktivierungsanker (0xFC26=0x8000) verletzt.' }

# --- PHY-RAM-Code (rtl8168_set_phy_mcu_8168gu_2, CFG_METHOD_25) ---
$phyBody = Find-FunctionBody 'rtl8168_set_phy_mcu_8168gu_2'
$phyOps = @()
$rmwState = 0
foreach ($line in $phyBody) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^rtl8168_mdio_write\(tp,\s*(0x[0-9A-Fa-f]+),\s*(0x[0-9A-Fa-f]+)\);$') {
        $reg = [Convert]::ToUInt32($Matches[1], 16)
        $val = [Convert]::ToUInt32($Matches[2], 16)
        switch ($reg) {
            0x1F { $phyOps += ,@('page', $val) }
            0x13 { $phyOps += ,@('addr', $val) }
            0x14 { $phyOps += ,@('data', $val) }
            default { throw "Unerwartetes MDIO-Register 0x$('{0:X}' -f $reg): $line" }
        }
    } elseif ($trimmed -eq 'gphy_val = rtl8168_mdio_read(tp, 0x17);') {
        $rmwState = 1
    } elseif ($trimmed -eq 'gphy_val &= ~(BIT_0);') {
        if ($rmwState -ne 1) { throw 'RMW-Sequenz unerwartet.' }
        $rmwState = 2
    } elseif ($trimmed -eq 'rtl8168_mdio_write(tp, 0x17, gphy_val);') {
        if ($rmwState -ne 2) { throw 'RMW-Sequenz unerwartet.' }
        $phyOps += ,@('rmw17_clear_bit0', 0)
        $rmwState = 0
    } elseif ($trimmed -match 'set_phy_mcu_patch_request|clear_phy_mcu_patch_request|^rtl8168_set_phy_mcu_8168gu_2|^\{$|^\}$|struct rtl8168_private|unsigned int gphy_val;|^$') {
        # Rahmen/Handshake: der Lader implementiert Request/Clear selbst.
    } else {
        throw "Unerwartete PHY-Zeile: $line"
    }
}
if ($phyOps.Count -ne 38) { throw "PHY-Op-Zahl unerwartet: $($phyOps.Count) statt 38" }

# --- Zig-Datei erzeugen ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('// GENERIERT von Code/System/Driver/RTL8168/Generator/Export-Rtl8168FirmwareTables05922.ps1')
[void]$sb.AppendLine('// aus Reference/Hardware/RTL8168/r8168-realtek-vendor/r8168_n.c (GPL-2.0):')
[void]$sb.AppendLine('//   rtl8168_set_mac_mcu_8168gu_2  (CFG_METHOD_25, RTL8168GU XID 0x509)')
[void]$sb.AppendLine('//   rtl8168_set_phy_mcu_8168gu_2  (CFG_METHOD_25, RTL8168GU XID 0x509)')
[void]$sb.AppendLine('// NICHT von Hand editieren; bei Bedarf Generator erneut ausfuehren.')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('pub const MacWrite = struct { addr: u16, value: u16 };')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('pub const PhyOpKind = enum(u8) { page, addr, data, rmw17_clear_bit0 };')
[void]$sb.AppendLine('pub const PhyOp = struct { kind: PhyOpKind, value: u16 };')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("pub const mac_mcu_gu2 = [_]MacWrite{")
foreach ($pair in $macPairs) {
    [void]$sb.AppendLine(('    .{{ .addr = 0x{0:X4}, .value = 0x{1:X4} }},' -f $pair[0], $pair[1]))
}
[void]$sb.AppendLine('};')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("pub const phy_ram_code_gu2 = [_]PhyOp{")
foreach ($op in $phyOps) {
    [void]$sb.AppendLine(('    .{{ .kind = .{0}, .value = 0x{1:X4} }},' -f $op[0], $op[1]))
}
[void]$sb.AppendLine('};')

[IO.File]::WriteAllText($targetPath, $sb.ToString().Replace("`r`n", "`n"))
Write-Host "Tabellen erzeugt: $targetPath"
Write-Host "MAC-MCU-Writes: $($macPairs.Count), PHY-Ops: $($phyOps.Count)"
