# Show HN post — draft

## Title

Pick **one**. HN titles cannot be editorialized after submission, so this
matters more than the body. Under 80 chars is best.

**Recommended (technical hook leads):**

```
Show HN: Lurar – macOS menu-bar EQ using Core Audio Process Tap, no BlackHole
```

**Alternative (user-benefit hook leads):**

```
Show HN: Lurar – free system-wide parametric EQ for macOS, loads AutoEq presets
```

**Alternative (curiosity hook):**

```
Show HN: A macOS system-wide EQ without a virtual audio driver
```

The first one is the best fit for HN — it's specific, technical, and signals
the novel thing immediately. Anyone who's tried to build cross-app audio on
macOS in the last decade knows the BlackHole / Soundflower / Loopback story
and will click on "no BlackHole" out of pure curiosity.

## Body

HN posts do not require a body, but a short one explaining what's new
technically converts well. No marketing voice; first person; link the source
and the binary.

```
Hi HN — I built Lurar because every system-wide EQ on macOS still ships a
virtual audio driver (BlackHole, Loopback, eqMac's old kext, Rogue Amoeba's
ARK). That was the only way to intercept other apps' audio until macOS 14.2
shipped the Core Audio Process Tap API in late 2023. Lurar uses the new API
instead: it taps audio at the process level, runs it through a 10-band vDSP
biquad EQ, and plays the result on the user's chosen DAC via a raw HAL
Audio Unit. No driver to install, no kext, no aggregate device the user has
to set as default output.

It also ships the AutoEq catalog (Oratory1990, Crinacle, etc.) as a built-in
preset browser, so headphone owners pick their model from a list and get a
measured correction curve in one click rather than copy-pasting filter
coefficients into someone's GUI.

A few things I learned while building it that might interest people here:

- The Process Tap API is read-only from the tap's perspective — you don't
  replace the app's output, you observe it. To actually EQ the audio
  user-side, the tap is paired with an aggregate device and the original
  apps keep playing to that aggregate while Lurar plays the processed
  version to the real DAC. It works, but the docs essentially don't exist
  yet; I reverse-engineered a lot of it from header comments and dtrace.
- AVAudioEngine adds buffering and rate conversion that's fine for a game
  but audible on a 32-bit float DSP chain. Lurar uses HAL Audio Units
  directly, which is a 2008-era API but the only way to keep the signal
  path Float32 end-to-end and pin the sample rate.
- TCC ("Audio Capture" permission) is annoyingly inconsistent — the orange
  mic indicator only lights up if you read the tap through a HAL input AU,
  not through `AudioDeviceIOProc` on a private aggregate device. Same
  permission, same data, different UI.
- HAL hog / exclusive-mode apps (some hi-res music players) bypass the
  mixer and can't be tapped. That's an OS-level constraint, not a Lurar
  bug, and as far as I can tell no tap-based tool can ever solve it.

Free, open source, no account, no telemetry, no paid tier. Signed and
notarized. macOS 14.2 or later, Apple Silicon and Intel.

Site (with download): https://lurar.app/
Source: https://github.com/lsjoberg/lurar

Happy to answer Core Audio / DSP / macOS audio questions.
```

## Before posting — checklist

- [ ] DMG is signed with a Developer ID cert *and* notarized + stapled.
      HN will catch an unsigned binary in the first comment and the thread
      dies. Test on a fresh Mac account that has never run Lurar.
- [ ] `lurar.app/` works without JS and serves a working download link.
- [ ] First-run experience is debugged on a clean machine: TCC prompt fires,
      audio comes through, no obvious bugs in the onboarding flow.
- [ ] README has a license file. ("Open source" with no LICENSE will be the
      top comment.)
- [ ] You're available for the **first 2 hours** after posting. HN ranking
      heavily weights early engagement; answering comments fast keeps the
      post on the front page.
- [ ] Optional: a 20-second loom / screen recording embedded in the README
      showing the AutoEq picker → engine on → EQ live. HN doesn't render
      video inline but linkers love it.

## Timing

Post **Tuesday–Thursday, 8–10am Pacific** for the best front-page chance.
Avoid Friday afternoon and weekends. Do not post the same week as a major
Apple event (WWDC, October Mac event) — the front page gets crowded.

## What not to do

- Don't crosspost to r/programming or lobste.rs simultaneously. Stagger by
  at least a day, and let HN finish its ranking cycle first.
- Don't reply to every comment with "thanks!". Engage substantively or stay
  quiet. HN downweights low-content replies from OPs.
- Don't compare Lurar negatively to SoundSource / Sonarworks by name unless
  asked. Let commenters bring up alternatives; agree they're good products
  with different tradeoffs.
- Don't argue with audiophile commenters about whether EQ "ruins" the sound.
  It's a religious war and the thread is not the place. "Some people prefer
  flat, some prefer Harman, Lurar lets you pick" is the only correct reply.

## After the post

- Save the comments. The criticism is more valuable than the upvotes — HN
  audio nerds will surface bugs and edge cases nothing else will.
- If the post hits the front page, your site will get 5k–50k hits in the
  first 6 hours. GitHub Pages can handle it; the DMG is hosted on GitHub
  Releases, which can also handle it. No CDN work needed.
