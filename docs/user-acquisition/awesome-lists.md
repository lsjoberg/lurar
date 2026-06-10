# "Awesome" list submissions — draft

This is the real replacement for the old AutoEq-README idea. AutoEq dropped its
in-README list of third-party frontends (the app list now lives inside the
autoeq.app web app, and the maintainer explicitly keeps it minimal), so a PR
there has nowhere to land. Curated GitHub "awesome" lists do the same job —
get Lurar in front of people already shopping for a tool — **and** these
maintainers actively accept additions, unlike AutoEq.

Same instinct as the original draft (one-line entry in a curated list), pointed
at lists that will actually merge it.

## Product facts to reuse verbatim

- **Name:** Lurar
- **Site:** <https://lurar.app/>
- **Source:** <https://github.com/lsjoberg/lurar>
- **License:** MIT — free, open source, no account, no telemetry
- **Platform:** macOS 14.2+, Apple Silicon & Intel, signed & notarized
- **One-liner:** menu-bar parametric EQ for headphones that loads the AutoEq
  catalog and applies it system-wide via Apple's Core Audio Process Tap — no
  BlackHole / virtual audio driver.

## Targets (ranked)

### 1. `jaywcjlove/awesome-mac` — highest reach

~80k stars; the default "awesome Mac apps" reference. Add under **Audio and
Video Tools › Audio Record and Process** (skim the live file — the exact
sub-heading drifts; an "Audio" or "Music" subsection is the right home if that
one's been renamed).

This list uses `*` bullets and reference-style badge icons (`[OSS Icon]`,
`[Freeware Icon]`) that are defined once at the bottom of its README, so they
resolve automatically once your line is in the file.

```markdown
* [Lurar](https://lurar.app/) - System-wide parametric EQ for headphones. Taps every app's audio via Apple's Core Audio Process Tap, runs a 10-band biquad EQ from the AutoEq catalog, and plays it on your DAC — no BlackHole or virtual audio driver. [![Open-Source Software][OSS Icon] ![Freeware][Freeware Icon]](https://github.com/lsjoberg/lurar)
```

### 2. `iCHAIT/awesome-macos`

~24k stars. Add under the **Audio** section. Uses `-` bullets; badge placement
differs slightly (open-source badge links the repo, freeware badge trails it):

```markdown
- [Lurar](https://lurar.app/) - Menu-bar parametric EQ for headphones with the AutoEq catalog built in. Uses Apple's Core Audio Process Tap (macOS 14.2+) instead of a virtual audio driver. [![Open-Source Software][OSS Icon]](https://github.com/lsjoberg/lurar) ![Freeware][Freeware Icon]
```

### 3. `serhii-londar/open-source-mac-os-apps`

~43k stars, scoped to **open-source** Mac apps — a perfect fit because Lurar is
MIT. Add under the **Audio** category. This list links the entry to the repo
itself and keeps descriptions terse; match the surrounding lines:

```markdown
- [Lurar](https://github.com/lsjoberg/lurar) - Menu-bar parametric EQ for headphones. Loads the AutoEq catalog and applies it system-wide via Apple's Core Audio Process Tap — no virtual audio driver. (<https://lurar.app/>)
```

## Per-PR checklist

- [ ] Re-read the target section's current heading before editing — these lists
      get reorganized; slot into whatever the Audio/EQ subsection is actually
      called now.
- [ ] Match the file's exact format: bullet character (`*` vs `-`), badge
      placement, and trailing period. Copy a neighboring entry and swap the text.
- [ ] One list per PR, one line per PR. Don't fix unrelated typos — single-purpose
      PRs get merged fastest.
- [ ] Follow each repo's `CONTRIBUTING.md` / PR template if present (several of
      these run a link-checker CI; make sure both URLs 200).
- [ ] Open from your own account and write the PR body in the first person —
      "I built Lurar, a free open-source…". Keep it to 2–3 sentences.
- [ ] Alphabetical ordering: a few of these lists sort entries within a section.
      Check and insert in the right spot if so.

## Suggested PR title / body (adapt per list)

Title:

```
Add Lurar to the Audio section
```

Body:

```markdown
I built Lurar, a free, open-source (MIT) macOS menu-bar parametric EQ for
headphones. It loads the AutoEq catalog and applies the correction system-wide
using Apple's Core Audio Process Tap API (macOS 14.2+) — so unlike most macOS
EQ tools it needs no BlackHole / virtual audio driver.

- Site: https://lurar.app/
- Source: https://github.com/lsjoberg/lurar
- License: MIT · signed + notarized · Apple Silicon and Intel

Single-line addition under Audio. Happy to adjust wording or placement.
```

## Note on session tooling

These PRs target third-party repos, so they can't be opened from a Claude Code
session scoped to `lsjoberg/lurar` — submit them from your own GitHub account
(fork → edit → PR), or re-scope a session to the target repo first.
