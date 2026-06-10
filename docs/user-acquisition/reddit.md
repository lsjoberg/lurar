# Reddit posts — drafts

Two subreddits with genuinely aligned audiences: **r/macapps** (native, free,
privacy-respecting Mac utilities) and the headphone-enthusiast crowd that
already lives in AutoEq presets. Reddit self-promotion rules are stricter than
HN — read each sub's rules before posting; the etiquette notes below are the
part that actually keeps the post up.

Reuse the same honest, first-person, no-marketing voice as the Show HN draft.

---

## r/macapps — primary, lowest friction

r/macapps explicitly welcomes developers posting their own apps. It rewards:
free, native, no telemetry, no subscription. Lead the title with the price tag
in brackets — that subreddit's convention.

### Title

```
[Free] Lurar — system-wide headphone EQ for macOS, loads AutoEq presets, no virtual driver
```

### Body

```
I built Lurar, a free and open-source menu-bar parametric EQ for headphones on
macOS.

What's different from the usual EQ tools: it doesn't install a virtual audio
driver (no BlackHole, no Loopback, no kext, no aggregate device you have to set
as default output). It uses Apple's Core Audio Process Tap API (macOS 14.2+) to
tap every app's audio, runs it through a 10-band biquad EQ, and plays the result
on whatever DAC you choose.

The AutoEq catalog (Oratory1990, Crinacle, etc.) is built in — pick your
headphones from a list and get a measured correction curve in one click, no
copy-pasting filter coefficients.

Other bits:
- A/B compare, including a loudness-matched blind mode
- Bauer-style crossfeed and ISO 226 equal-loudness compensation
- Remembers the last preset per output device
- Per-app exclusion, hold-to-bypass hotkey, optional iCloud preset sync

Free, MIT-licensed, no account, no telemetry. Signed and notarized.
macOS 14.2 or later, Apple Silicon and Intel.

Site & download: https://lurar.app/
Source: https://github.com/lsjoberg/lurar

Happy to answer macOS audio / Core Audio questions.
```

### Etiquette

- Post as a self/text post, not a link post — r/macapps prefers the description
  in-thread.
- Set the **Developer** / "I made this" flair if the sub has one; not disclosing
  that you're the author is the fastest way to get removed.
- Reply to questions; don't reply "thanks!" to praise.

---

## Headphone enthusiasts — r/headphones (and adjacent)

This is the AutoEq audience, but it's also where self-promotion rules bite
hardest. **Read the rules first.** r/headphones restricts vendor/self-promo and
often funnels app posts into a weekly thread or requires established account
history + mod approval. Don't drive-by-drop a download link in a fresh post.

Better-aligned, friendlier alternatives for the first post:
- **r/oratory1990** — the home of the Oratory1990 measurements Lurar ships.
- **r/AutoEq** if active, and the AutoEq discussion threads generally.
- The r/headphones weekly "self-promotion" / app thread when one is running.

Lead with the AutoEq angle there, not the macOS-tech angle — this audience cares
about the presets, not the Process Tap API.

### Title

```
Free macOS app that loads AutoEq presets system-wide (no BlackHole / virtual driver)
```

### Body

```
For the Mac users here who use AutoEq: I made a free, open-source app called
Lurar that loads the AutoEq catalog and applies the correction to everything
your Mac plays.

You pick your headphones from the built-in AutoEq list (Oratory1990, Crinacle)
and the curve goes live in one click. It applies system-wide without installing
a virtual audio driver — it uses Apple's Core Audio Process Tap API on macOS
14.2+, so there's no BlackHole / Loopback / aggregate-device setup.

It also has crossfeed, equal-loudness compensation, and a loudness-matched blind
A/B mode if you want to sanity-check a curve against flat.

MIT-licensed, no account, no telemetry. https://lurar.app/

Not trying to replace anyone's PEQ workflow — just wanted a one-click way to run
the measured curves system-wide on a Mac without the driver dance. Feedback from
this crowd is exactly what I want.
```

### Etiquette

- Disclose authorship in the first line. Audiophile subs are ruthless about
  undisclosed self-promo.
- Don't position it against eqMac / SoundSource / Sonarworks unless asked. If
  someone brings them up, agree they're good and note the different tradeoffs.
- Stay out of "EQ ruins the sound" arguments — "some prefer flat, some prefer
  Harman, Lurar lets you pick" is the only reply that doesn't start a war.

---

## Timing & sequencing

- Post **r/macapps first**; it's the safest and the feedback will surface any
  obvious first-run bug before a stricter audience sees it.
- Stagger channels — don't post r/macapps, the headphone sub, and Show HN the
  same day. Give each a day to run its ranking cycle.
- Weekday mornings US time get the most eyes; avoid Friday/weekend.

## Pre-post checklist (shared with Show HN)

- [ ] DMG at the download link is signed + **notarized + stapled**; verify on a
      Mac with `spctl -a -t open --context context:primary-signature` and
      `stapler validate`.
- [ ] First-run tested on a clean macOS user account (TCC prompt fires, audio
      passes through, onboarding has no obvious bug).
- [ ] You're available to answer comments for the first few hours after posting.
