# Lurar

A macOS menu bar parametric EQ for headphone listening. Captures every app's audio via a Core Audio Process Tap, runs it through a 10-band vDSP biquad EQ, and plays the result through your DAC via a raw HAL Audio Unit (no AVAudioEngine, no BlackHole, no virtual loopback driver).

**[Download for macOS →](https://lurar.app/)**

## Prerequisites (development)

```bash
brew install xcodegen
```

That's it — no audio driver to install. Requires macOS 14.2 or later (Core Audio Process Tap API).

## Build & run

```bash
./scripts/dev.sh
```

That regenerates the Xcode project, builds with ad-hoc signing, kills any running instance, and launches the fresh `Lurar.app`. No Xcode UI required — no signing team to configure.

On first engine-on, macOS prompts for **Audio Capture** permission. Grant it. Lurar also declares the `com.apple.security.device.audio-input` entitlement, which is required by Core Audio to deliver tap samples even with TCC granted — but it does **not** bring up the orange microphone indicator, because the tap is read via `AudioDeviceIOProc` on a private aggregate device, not a HAL input AU.

In a second terminal, tail OSLog output:

```bash
./scripts/logs.sh
```

## Use

1. Lurar menu bar → set **Output** to the device you actually want to listen on (e.g. **HIFIMAN-EF500**). Lurar takes care of routing — you don't need to change anything in System Settings → Sound.
2. Pick a preset. Lurar ships with a **Flat** preset; choose **Add more presets…** in the picker to browse the AutoEq catalog (Oratory1990 measurements for HiFiMan Arya Stealth et al.) and add ones for your headphones.
3. Toggle the engine **ON** and accept the audio-capture prompt the first time.
4. Play audio in any app — it flows: app → process tap → Lurar DSP → HALOutput → DAC → headphones.

Tap *Open Editor…* for live band tweaking. Edits apply to the running engine instantly. Built-in presets are read-only — use **Tweak…** to fork one into your library; the original stays visible as a dashed reference curve, and **Reset to Original** beside the "Derived from …" chip undoes your divergence. **New preset…** in the preset dropdown creates a fully custom preset from scratch (10 log-spaced bands at unity gain). **Save** persists edits, **Discard Changes** throws away unsaved edits, and **Delete** removes a preset.

### Known limitations

- Apps using HAL hog / exclusive mode (some hi-res music players) bypass Core Audio's mixer entirely and can't be tapped. Switch those apps off exclusive mode if you want them EQ'd.
- Third-party HAL drivers can intercept tap data. Rogue Amoeba's ARK driver (SoundSource, Audio Hijack, Loopback) is the most common culprit — if you're getting silence in the EQ'd path, quit the corresponding app and run `launchctl bootout gui/$(id -u)/com.rogueamoeba.arkaudiod`.

## Presets

User-editable JSON lives at `~/Library/Application Support/Lurar/presets.json`. Lurar watches the file and reloads on save (debounced ~150 ms). Add new headphones by appending objects to the array — the schema is on `EQPreset.swift`.

## Reset to scratch

Lurar persists state in three places. Each is independently resettable; pick what you need.

**`~/Library/Application Support/Lurar/`** — files Lurar owns

| Path | What it stores |
| --- | --- |
| `presets.json` | Your editable preset library |
| `enabledBuiltIns.json` | Which AutoEq catalog entries you've turned on |
| `Catalog/index.json` | Cached parse of AutoEq's `INDEX.md` |
| `Catalog/presets/*.json` | Per-headphone hydrated preset cache |

**`~/Library/Preferences/app.lurar.Lurar.plist`** — UserDefaults

| Key | Meaning |
| --- | --- |
| `lurar.loudnessOffsetDB` | Loudness slider position |
| `lurar.presets.migratedBuiltIns_v1` | One-shot migration done |
| `lurar.lastPresetByDevice` | `[deviceUID: presetUUID]` map for per-device auto-recall |
| `lurar.suggestionsDismissedDevices` | Device UIDs you said *Not now* to in the auto-detect banner |
| `crossfeed.intensity`, `crossfeed.cutoff` | Crossfeed settings |
| `spectrum.enabled` | Spectrum overlay toggle in the editor |

**TCC** — system-managed audio-capture grant for `app.lurar.Lurar`.

> ⚠️ Quit Lurar before running any of these recipes. `@AppStorage`-backed
> values are cached in the live process and won't re-read from disk until
> the app relaunches; TCC state changes are picked up at engine start, so
> a quit-and-relaunch is the simplest way to get a clean slate.

### Common reset recipes

Trigger the first-run onboarding window again:

```bash
# Quit Lurar first
tccutil reset AudioCapture app.lurar.Lurar
# Relaunch Lurar → menu bar → toggle Engine ON
```

Wipe just the user preset library (keeps catalog cache and preferences):

```bash
# Quit Lurar first
rm ~/Library/Application\ Support/Lurar/presets.json
```

Force a fresh catalog fetch from AutoEq (keeps user presets):

```bash
# Quit Lurar first
rm -rf ~/Library/Application\ Support/Lurar/Catalog
rm ~/Library/Application\ Support/Lurar/enabledBuiltIns.json
```

Forget per-device preset memory and re-enable the auto-detect banner on devices you previously dismissed:

```bash
# Quit Lurar first
defaults delete app.lurar.Lurar lurar.lastPresetByDevice
defaults delete app.lurar.Lurar lurar.suggestionsDismissedDevices
```

Reset all preferences but keep presets and catalog:

```bash
# Quit Lurar first
defaults delete app.lurar.Lurar
```

Nuke everything — Lurar back to the state of a brand-new install:

```bash
# Quit Lurar first
defaults delete app.lurar.Lurar
tccutil reset AudioCapture app.lurar.Lurar
rm -rf ~/Library/Application\ Support/Lurar
```

## Regenerating after editing `project.yml`

`./scripts/dev.sh` already runs `xcodegen generate` for you on every build. Run it manually only if you need to regenerate without building:

```bash
xcodegen generate
```

Keep `project.yml`, `Lurar/`, and `scripts/` under git; `Lurar.xcodeproj` and `build/` are gitignored.

## Releasing

Releases are fully automated by [release-please](https://github.com/googleapis/release-please) and a `macos-14` GitHub Actions runner.

**Commit convention:** the version bump is derived from [Conventional Commits](https://www.conventionalcommits.org/) on `main`:

| Prefix | Effect |
| --- | --- |
| `feat: …` | minor bump (`0.1.0 → 0.2.0`) |
| `fix: …` | patch bump (`0.1.0 → 0.1.1`) |
| `feat!: …` or `BREAKING CHANGE:` footer | major bump (`0.x.y → 1.0.0`) |
| `chore: … / docs: … / refactor: … / test: …` | no release |

**Cutting a release:**

1. Push conventional commits to `main`.
2. The release-please workflow opens (or updates) a `chore(main): release X.Y.Z` PR with the bumped `MARKETING_VERSION` in `project.yml`, an updated `CHANGELOG.md`, and a touched `.release-please-manifest.json`.
3. Merge that PR. release-please pushes a `vX.Y.Z` tag, which fires `release.yml`: archive → Developer ID sign → notarize → staple → DMG → GitHub Release → updated `docs/appcast.xml`.
4. The Pages workflow re-deploys the site (download button + appcast) within ~1 minute.

**Dry runs** (no signing certificate needed): run `release.yml` via *Actions → Release → Run workflow*. The build uses ad-hoc signing, skips notarization, and uploads the unsigned DMG as a workflow artifact. Useful for sanity-checking the pipeline before the Apple Developer Program enrollment goes through.

### Required GitHub secrets (signed mode)

| Secret | Where it comes from |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | `base64 -i cert.p12` of the Developer ID Application cert + private key exported from Keychain Access. |
| `P12_PASSWORD` | The password chosen at `.p12` export time. |
| `KEYCHAIN_PASSWORD` | `openssl rand -base64 24` — used only inside the temporary CI keychain. |
| `APPLE_ID` | Apple ID email address. |
| `APPLE_TEAM_ID` | 10-char Team ID from developer.apple.com → Membership. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password from appleid.apple.com → Sign-In and Security. |
| `SPARKLE_ED_PRIVATE_KEY` | Base64 EdDSA private key from running Sparkle's `generate_keys` **once**. **Back up to a password manager immediately** — losing it orphans every existing install. |

Plus one repository variable:

| Variable | Contents |
| --- | --- |
| `SPARKLE_PUBLIC_ED_KEY` | The matching public key (printed by `generate_keys` alongside the private one; not secret). |

### Required for release-please → release.yml chaining

| Secret | Why |
| --- | --- |
| `RELEASE_PLEASE_TOKEN` | A fine-grained PAT (account → Settings → Developer settings → Personal access tokens → Fine-grained → scope to `lsjoberg/lurar`, permissions `Contents: read & write` + `Pull requests: read & write`). Required because the default `GITHUB_TOKEN` cannot trigger downstream workflows — without this, release-please tags the release but `release.yml` never fires and the DMG never gets built. If the secret is absent, release-please falls back to `GITHUB_TOKEN` and you'll have to manually run `release.yml` against the new tag via *Actions → Release → Run workflow*. |

### Permanence of the Sparkle feed URL

`SUFeedURL` in `Lurar/Info.plist` (set to `https://lurar.app/appcast.xml`) is baked into every shipped binary. If the project ever gets renamed or moves off this domain, **this URL must keep serving a current appcast forever** — GitHub Pages does not support real HTTP redirects, so installed clients with old binaries will look for the file at this exact location indefinitely. Either keep `lurar.app` pointed at a Pages site serving the appcast, or update `SUFeedURL` *and* keep the old `appcast.xml` reachable at the prior URL.
