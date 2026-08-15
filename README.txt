USBDIAG.R4X
===========

USBDIAG.R4X ist die USB-Protokoll-Diagnose.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\UsbDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\UsbDiag\zig-out\USBDIAG.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `usbdiag_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4DEV`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\USBDIAG.R4X`
