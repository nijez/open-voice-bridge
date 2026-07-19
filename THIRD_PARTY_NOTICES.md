# Third-party notices

## remote-bridge-hub

- Project: `xxb26553663-star/remote-bridge-hub`
- Source: <https://github.com/xxb26553663-star/remote-bridge-hub>
- Reference revision: `8a93f321ac71a602300c6cd77f7256fa4b63068e`
- License: GNU General Public License v3.0 only (`GPL-3.0-only`)

The Xiaomi RC003 ATVV UUIDs, microphone command behavior, IMA/DVI ADPCM decoding order, capability parsing, and HID usage mapping in the first Open Voice Bridge adapter were adapted from this project. The macOS implementation uses Apple public frameworks and does not include the upstream Windows injection, VB-CABLE packaging, commercial branding, or customer systems. Other future device profiles do not inherit this attribution unless they actually use the upstream work.

The Windows source/build candidate at `apps/windows/rc003/` was informed by the same reference project and revision for the same interoperability facts (ATVV UUIDs/opcodes, IMA/DVI ADPCM tables, RC003 HID usage IDs and VID/PID). It is a clean-room Python reimplementation, not a port of upstream's Windows source files; see `apps/windows/rc003/ATTRIBUTION.md` for the file-by-file record. It does not include the upstream VB-CABLE driver packaging, Frida injection/gadget binary, T1/V60 device bridges, or commercial branding, and has not completed real-Windows-device acceptance.

## Frida Gadget (optional, not bundled)

`apps/windows/rc003/build/fetch-frida-gadget.ps1` can optionally download the official Frida Gadget release asset (`frida-gadget-17.15.3-windows-x86_64.dll.xz` from `github.com/frida/frida`) and verifies its SHA-256 (`b566d70189b6d551ad8f4e0bea24de08a3d4c0f559bb35b2bdb67d45182240c2`) before use. No Frida binary is committed to this repository, downloaded automatically by any normal build or test step, or required for the application to run. This candidate does not implement the actual gadget-injection step (see `apps/windows/rc003/README.md`), so fetching this asset currently has no effect on the running application. Frida is licensed separately from this project (its own license text is fetched from `raw.githubusercontent.com/frida/frida-core/main/COPYING`) and is not authored by, or affiliated with, this project or its upstream reference.

## VB-Audio VB-CABLE (optional; official Basic package bundled offline as of XRBM-031)

VB-CABLE is an independent product by VB-Audio (<https://www.vb-cable.com>, licensing terms at <https://vb-audio.com/Services/licensing.htm>), distributed under VB-Audio's own Donationware terms — it is not GPL-3.0 project code, is not authored by or affiliated with this project, and users remain free (and encouraged) to donate to or license it directly with VB-Audio. Open Voice Bridge does not modify, re-license, or redistribute a changed copy of it.

Through XRBM-030, this candidate's documentation only ever mentioned VB-CABLE as something a user could separately download and install entirely at their own discretion. As of XRBM-031, `apps/windows/rc003/build/fetch-vb-cable.ps1` additionally downloads the official, unmodified VB-CABLE Basic driver pack (`VBCABLE_Driver_Pack45.zip`) over HTTPS and verifies its SHA-256 against a pin recorded in `apps/windows/rc003/src/ovb_rc003/vb_cable_bundle.py`, and the frozen Windows build bundles that verified, unmodified ZIP as ordinary application data — so the "检查与修复" (check-and-repair) settings page can offer an install option that works fully offline, with no separate download step for the end user. Only the free Basic package is ever fetched or bundled; the paid A+B/C+D bundles are never downloaded, bundled, or referenced.

Bundling the installer does not mean this project installs the driver: the application itself never runs with administrator privileges, never silently installs or configures anything, and never reports a driver install as successful merely because a process was launched. Installing (or repairing/removing) VB-CABLE only ever happens when a user explicitly clicks an install action in the settings page, confirms a second explicit dialog, and then approves (or can cancel) a real Windows User Account Control (UAC) prompt that launches VB-Audio's own, unmodified `VBCABLE_Setup_x64.exe` — the same experience as manually downloading and running that installer from <https://vb-audio.com/Cable/> would be. At runtime, voice output is still written only to a Windows audio endpoint the user has explicitly selected by name in the application's own settings window — never a default device, and never anything auto-picked — and this project never changes the Windows system default input/output device, during driver setup or otherwise.

## BlackHole

BlackHole is not bundled, downloaded, or installed by this project. The application can send decoded PCM to any user-selected CoreAudio output device; BlackHole is only a documented optional loopback-device choice.

## Qt for Python (PySide6-Essentials)

- Project: Qt for Python (PySide6)
- Source: <https://www.qt.io/qt-for-python> / <https://pypi.org/project/PySide6-Essentials/>
- License: per Qt's own documentation, the Qt for Python community edition is available under open-source terms (LGPLv3, with some modules under GPLv3) or under a commercial Qt license. This project uses only the open-source community edition installed from PyPI, under no commercial license.

`apps/windows/rc003/`'s settings window (XRBM-030) is built with `PySide6-Essentials`, the official Python bindings for Qt 6 (Qt Quick/QML, used here for the "连接"/"按键"/"权限" settings UI that replaced an earlier Tkinter candidate). This project only depends on the `PySide6-Essentials` distribution (not the separately-packaged `PySide6-Addons`), uses it exactly as published on PyPI with no modification to Qt's own source, and installs it as an ordinary Python dependency (`apps/windows/rc003/requirements.txt`) whose own shared libraries/plugins are collected unmodified into the frozen build by PyInstaller's bundled PySide6 hooks. No claim is made here about which specific license clause governs this particular usage beyond that; see Qt's own licensing documentation for the authoritative terms. Qt/PySide6 is not authored by, and is not affiliated with, this project or its upstream RC003 reference implementation.

## RC003 product photo

The RC003 product photo bundled as `RC003-remote-photo.png` was supplied by the user on 2026-07-17 for the physical-button mapping interface. It is preserved at its original 508 x 1030 aspect ratio. Copyright and trademark rights in the photo and depicted products remain with their respective owners; the GPL-3.0-only license for the program does not grant additional rights to this image or the Xiaomi marks.
