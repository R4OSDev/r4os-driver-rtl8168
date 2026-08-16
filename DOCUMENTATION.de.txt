RTL8168.R4D
===========

RTL8168.R4D ist der native Descriptor-DMA-Netzwerktreiber fuer Realtek-
Controller mit PCI-ID 10EC:8168. Das erste Hardware-Abnahmeziel ist
Subsystem 17AA:38C7, Revision 10 (RTL8111/RTL8168 im Lenovo-Laptop).

Der Treiber verwendet 64 RX- und 16 TX-Deskriptoren, taskkontextbasiertes
Polling mit optionalen shared INTx-Hinweisen, PCI-PM-D0 und ein defensives
Abschalten von PCIe-ASPM-L1 am Endpunkt. Der Firmware-PHY-Zustand bleibt bei
unbekannten XIDs unangetastet.

Build:

    cd Code\System\Driver\RTL8168
    ..\..\..\..\DevTools\Zig\zig.exe build

Artefakt: zig-out\RTL8168.R4D
Image-Ziel: C:\R4OS\DRIVERS\RTL8168.R4D

Bekannte Grenze: Die aktuelle DriverAPI adressiert nur die PCI-Funktion des
Controllers. ASPM-L1 kann deshalb am Endpunkt, aber noch nicht am zugehoerigen
Upstream-Port abgeschaltet werden. Fuer XID-spezifische EPHY-Sequenzen und
Firmware-Blobs gibt es in R4OS noch keinen Firmware-Ladepfad.
