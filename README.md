# Klang

A macOS menu bar parametric EQ for headphone listening. Routes system audio through BlackHole → 4-band AVAudioEngine EQ → your DAC.

## Prerequisites

```bash
brew install xcodegen
brew install --cask blackhole-2ch
```

## Build & run

```bash
xcodegen generate
open Klang.xcodeproj
```

In Xcode, set your **Signing team** under *Signing & Capabilities* on the `Klang` target (one-time; `project.yml` deliberately leaves it blank so it isn't checked into git). Then ⌘R.

## Use

1. System Settings → Sound → Output → **BlackHole 2ch**.
2. Klang menu bar → pick your output device (e.g. **HIFIMAN-EF500**).
3. Pick a preset (ships with HiFiMan Arya Stealth · Oratory1990).
4. Toggle the engine **ON**.
5. Play audio — it flows: app → BlackHole → Klang DSP → DAC → headphones.

Tap *Open Editor…* for live band tweaking. Edits apply to the running engine instantly. Save as new preset / overwrite / duplicate from the editor.

## Presets

User-editable JSON lives at `~/Library/Application Support/Klang/presets.json`. Klang watches the file and reloads on save (debounced ~150 ms). Add new headphones by appending objects to the array — the schema is on `EQPreset.swift`.

## Regenerating after editing `project.yml`

```bash
xcodegen generate
```

Keep `project.yml` and `Klang/` under git; `Klang.xcodeproj` is gitignored.
