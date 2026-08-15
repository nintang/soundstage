<div align="center">

# SoundStage

**Play system audio through all your output devices at once — with per-device volume, latency alignment, and live metering. From your menu bar.**

![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-lightgrey)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

<img src="assets/hero.png" width="560" alt="SoundStage panel showing three output devices with volume, delay and meters" />

</div>

---

macOS lets you pick *one* output device. SoundStage removes that limit: your monitor's speakers, a Bluetooth speaker, and the built-in speakers can all play together — each with its own volume, its own delay to fix Bluetooth lag, and a live level meter. It's the "Multi-Output Device" from Audio MIDI Setup, if it had a volume mixer, latency alignment, and lived in your menu bar.

## Features

- 🔊 **All devices at once** — HDMI/DisplayPort monitors, Bluetooth speakers, built-in speakers, USB interfaces, AirPlay
- 🎚 **Per-device volume** (0–150%) plus master volume — something macOS multi-output can't do at all
- ⏱ **Per-device delay** (0–750 ms) — Bluetooth speakers lag behind wired ones; delay the wired outputs until the echo collapses into a single sound
- 📊 **Live level meters** for every device
- 🔌 **Auto-rejoin** — a Bluetooth speaker that reconnects automatically rejoins the mix
- ▶️ **Auto-resume** — quit while routing, and the next launch (or reboot, as a Login Item) picks up exactly where you left off
- 🫥 **Menu bar native** — SwiftUI `MenuBarExtra`, no Dock icon, ~2 MB, zero dependencies

## Install

**Download:** grab `SoundStage.app.zip` from [Releases](../../releases), unzip, drop into `/Applications`.

The app is not notarized (no paid developer account), so on first open macOS will complain. Clear it with:

```bash
xattr -dr com.apple.quarantine /Applications/SoundStage.app
```

…or right-click the app → **Open** → **Open**.

**Or build from source** (takes ~1 min, needs Xcode command line tools):

```bash
git clone https://github.com/TonAldo48/soundstage.git
cd soundstage && ./macos/make-app.sh
cp -R macos/build/SoundStage.app /Applications/
```

## First run

1. Click the ![tray](https://img.shields.io/badge/-%F0%9F%8E%9A-grey) sliders icon in your menu bar
2. Toggle on the devices you want, hit **▶ Start**
3. macOS asks for **System Audio Recording** permission — allow it (that's how SoundStage taps the audio stream; nothing is recorded or stored)

### Getting devices in sync

Bluetooth adds 100–300 ms of latency, so a Bluetooth speaker will echo behind wired outputs. You can't make Bluetooth faster — so make the others later:

> Play music → drag the **DLY** slider **up on the wired devices** (start around 150–200 ms) until the echo disappears.

Leave **Clock** on a wired device (built-in speakers are ideal). The clock device is the timing reference the others are drift-corrected against — Bluetooth clocks wander too much to lead.

### Start on boot

Add SoundStage to **System Settings → General → Login Items**. Combined with auto-resume, a reboot brings your whole mix back with zero clicks.

## How it works

```mermaid
flowchart LR
    A[Music app] --> T
    B[Browser] --> T
    C[Any process] --> T
    T["Core Audio process tap<br/>(muted-when-tapped)"] --> E["SoundStage engine<br/>ring buffer · per-device gain/delay"]
    E --> AG["Private aggregate device<br/>(drift compensation)"]
    AG --> D1[🖥 Monitor speakers]
    AG --> D2[📻 Bluetooth speaker]
    AG --> D3[💻 Built-in speakers]
```

SoundStage creates a **global Core Audio process tap** (`CATapDescription`, macOS 14.4+) that captures every process's audio and simultaneously mutes it at the hardware — so sound only reaches the devices *you* choose, with no doubling. The tap feeds a **private aggregate device** containing your selected outputs; Core Audio drift-corrects each device against the clock device, and the engine's realtime callback applies per-device gain, delay (a shared ring buffer read at per-device offsets), and RMS metering. No kernel extensions, no virtual audio drivers, no installers.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the deep dive.

## Limitations

- Audio is captured as a **stereo mixdown** — multichannel sources are folded to stereo before distribution
- Bluetooth latency **varies over time**; a delay that's perfect now may drift by tens of ms during a session
- Requires **macOS 14.4+** (the process-tap API is recent); Apple Silicon
- While routing is active, the volume keys control SoundStage's devices only via the panel (the system volume HUD is bypassed)

## License

[MIT](LICENSE) © David Nintang
