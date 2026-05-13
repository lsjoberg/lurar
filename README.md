# Klang

A macOS menu bar parametric EQ for headphone listening. Routes system audio through BlackHole → 4-band vDSP biquad EQ → your DAC via two raw HAL Audio Units (no AVAudioEngine).

## Prerequisites

```bash
brew install xcodegen
brew install --cask blackhole-2ch
```

## Build & run

```bash
./scripts/dev.sh
```

That regenerates the Xcode project, builds with ad-hoc signing, kills any running instance, and launches the fresh `Klang.app`. No Xcode UI required — no signing team to configure.

In a second terminal, tail OSLog output:

```bash
./scripts/logs.sh
```

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

`./scripts/dev.sh` already runs `xcodegen generate` for you on every build. Run it manually only if you need to regenerate without building:

```bash
xcodegen generate
```

Keep `project.yml`, `Klang/`, and `scripts/` under git; `Klang.xcodeproj` and `build/` are gitignored.
