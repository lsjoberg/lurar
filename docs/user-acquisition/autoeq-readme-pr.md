# AutoEq README PR — draft

Target repo: **jaakkopasanen/AutoEq** (`github.com/jaakkopasanen/AutoEq`)

The AutoEq README links third-party tools that consume its measurements. Lurar
qualifies: it pulls `INDEX.md` and the per-headphone preset JSON from AutoEq's
raw GitHub URLs, hydrates them into a 10-band parametric EQ, and applies them
system-wide on macOS. Adding a one-line entry is the highest-signal acquisition
channel we have — every visitor to that README is already a qualified user.

## Where to add it

AutoEq's README has historically had a section listing third-party apps that
load the presets. The exact heading drifts (it's been "Usage", "Tools", "Third
party software", "GUI apps"); skim the current `README.md` before editing and
add to whichever subsection lists per-platform EQ frontends. There's also a
table of macOS-specific tools — that's the right home if it still exists.

## Suggested entry (one-liner, table row)

```markdown
| [Lurar](https://lurar.app/) | macOS 14.2+ | Free, open source. Menu-bar parametric EQ. Browses and loads the AutoEq catalog directly — no manual file copying. Uses Apple's Core Audio Process Tap API, so no BlackHole / virtual driver is required. |
```

## Suggested entry (prose, if the list is bulleted)

```markdown
- **[Lurar](https://lurar.app/)** (macOS 14.2+, free, open source) — menu-bar
  parametric EQ that browses and loads the AutoEq catalog in-app. No virtual
  audio driver: routes via Apple's Core Audio Process Tap API (Sonoma 14.2+).
  Source: <https://github.com/lsjoberg/lurar>.
```

## PR title

```
docs(readme): add Lurar (macOS) to the list of AutoEq frontends
```

## PR body

```markdown
Lurar is a free, open-source macOS menu-bar parametric EQ that consumes the
AutoEq catalog directly: it fetches `INDEX.md` and the per-headphone preset
JSON from this repo's raw GitHub URLs, hydrates them into a 10-band biquad
chain, and applies the correction system-wide.

Unlike most macOS EQ tools, Lurar does not require BlackHole, Loopback, or any
other virtual audio device — it uses Apple's Core Audio Process Tap API
(introduced in macOS 14.2). Users pick their headphones from the AutoEq list
and the curve is live in one click.

- Site & download: https://lurar.app/
- Source: https://github.com/lsjoberg/lurar
- License: (fill in once decided — e.g. MIT)
- Platform: macOS 14.2 or later, Apple Silicon and Intel, signed + notarized

Happy to adjust wording or location in the README.
```

## Before opening the PR — checklist

- [ ] Pick a license and make sure `LICENSE` is in the repo root. AutoEq's
      audience will ask, and "open source" with no `LICENSE` file reads as
      sloppy.
- [ ] Confirm the entry slots into whatever the current section is actually
      called — re-read the live README.
- [ ] If there's a `CONTRIBUTING.md` or PR template, follow it.
- [ ] Open the PR from a personal fork, not the org account, and write it in
      the first person — "I built Lurar, …" — maintainers respond better to
      humans than to apps.
- [ ] Don't bundle anything else (no fixing of typos elsewhere in the README).
      Single-purpose PRs get merged faster.

## Why this is the highest-leverage channel

Every other channel (Head-Fi, Reddit, ASR) reaches some headphone enthusiasts.
The AutoEq README reaches **the exact subset of headphone enthusiasts who are
about to install an EQ tool to load AutoEq presets**. Conversion rate should
be an order of magnitude higher than anywhere else.
