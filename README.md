# Klang

A macOS menu bar parametric EQ for headphone listening. Captures every app's audio via a Core Audio Process Tap, runs it through a 10-band vDSP biquad EQ, and plays the result through your DAC via a raw HAL Audio Unit (no AVAudioEngine, no BlackHole, no virtual loopback driver).

## Prerequisites

```bash
brew install xcodegen
```

That's it — no audio driver to install. Requires macOS 14.2 or later (Core Audio Process Tap API).

## Build & run

```bash
./scripts/dev.sh
```

That regenerates the Xcode project, builds with ad-hoc signing, kills any running instance, and launches the fresh `Klang.app`. No Xcode UI required — no signing team to configure.

On first engine-on, macOS prompts for **Audio Capture** permission. Grant it. Klang also declares the `com.apple.security.device.audio-input` entitlement, which is required by Core Audio to deliver tap samples even with TCC granted — but it does **not** bring up the orange microphone indicator, because the tap is read via `AudioDeviceIOProc` on a private aggregate device, not a HAL input AU.

In a second terminal, tail OSLog output:

```bash
./scripts/logs.sh
```

## Use

1. System Settings → Sound → Output → the device you actually want to listen on (e.g. **HIFIMAN-EF500**). This is also what the tap rides for clock; apps' direct output to this device is muted while the engine is on.
2. Klang menu bar → set Output to the same device.
3. Pick a preset. Klang ships with a **Flat** preset; choose **Add more presets…** in the picker to browse the AutoEq catalog (Oratory1990 measurements for HiFiMan Arya Stealth et al.) and add ones for your headphones.
4. Toggle the engine **ON** and accept the audio-capture prompt the first time.
5. Play audio in any app — it flows: app → process tap → Klang DSP → HALOutput → DAC → headphones.

Tap *Open Editor…* for live band tweaking. Edits apply to the running engine instantly. Built-in presets are read-only — use **Save As New…** to keep your changes. **Save** persists edits to your own presets; **Delete** removes them.

### Known limitations

- Apps that start producing audio **after** the engine is toggled on aren't tapped until you toggle Engine off → on. (The tap target list is enumerated at start; a process-list listener is a possible follow-up.)
- Apps using HAL hog / exclusive mode (some hi-res music players) bypass Core Audio's mixer entirely and can't be tapped. Switch those apps off exclusive mode if you want them EQ'd.
- Third-party HAL drivers can intercept tap data. Rogue Amoeba's ARK driver (SoundSource, Audio Hijack, Loopback) is the most common culprit — if you're getting silence in the EQ'd path, quit the corresponding app and run `launchctl bootout gui/$(id -u)/com.rogueamoeba.arkaudiod`.

## Presets

User-editable JSON lives at `~/Library/Application Support/Klang/presets.json`. Klang watches the file and reloads on save (debounced ~150 ms). Add new headphones by appending objects to the array — the schema is on `EQPreset.swift`.

## Regenerating after editing `project.yml`

`./scripts/dev.sh` already runs `xcodegen generate` for you on every build. Run it manually only if you need to regenerate without building:

```bash
xcodegen generate
```

Keep `project.yml`, `Klang/`, and `scripts/` under git; `Klang.xcodeproj` and `build/` are gitignored.
