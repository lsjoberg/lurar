# Changelog

## [0.3.0](https://github.com/lsjoberg/lurar/compare/v0.2.3...v0.3.0) (2026-05-19)


### Features

* **audio:** fade engine start, stop, app-quit, and 150 ms startup mute ([3a182ef](https://github.com/lsjoberg/lurar/commit/3a182ef0f52c1fed654ac55cc9eb69631f169d4b))
* **audio:** pin HAL Output sample rate, bridge tap rate with AudioConverter ([11340db](https://github.com/lsjoberg/lurar/commit/11340db22126e50454e3a817bf30f631cebddae6))
* **audio:** runtime diagnostics + fade-mute on output device rate change ([cdfb036](https://github.com/lsjoberg/lurar/commit/cdfb036617baba4b6ffae73ccd2c5ecadebd0fbf))
* **library:** nudge toward recommended measurement sources ([8a525c3](https://github.com/lsjoberg/lurar/commit/8a525c3368bfd1f887da6a75a402e5206cf0c7ee))
* **onboarding:** kickstart new users after consent with output + presets ([51bb009](https://github.com/lsjoberg/lurar/commit/51bb009a2bdfe19f193bb1ce06645af33d5e718f))
* **onboarding:** prefer recommended measurement sources ([aa61b9c](https://github.com/lsjoberg/lurar/commit/aa61b9cd56d91a02f9df3980897287bba59c633c))
* **prefs:** auto-follow system default output by default, as a switch ([485f9c6](https://github.com/lsjoberg/lurar/commit/485f9c68660439f193f036a7e370c5b42b05354c))
* **settings:** per-output burn-in counter ([558f59c](https://github.com/lsjoberg/lurar/commit/558f59cee536e19043b6e872c91e7068c2baab39))
* **ui:** gate menu-bar popover behind TCC consent ([7cb56ab](https://github.com/lsjoberg/lurar/commit/7cb56ab1478e0bfc584b95e632a9bb04fa4a9935))


### Bug Fixes

* **audio:** smooth track-change rebuilds with fade + skip-if-unchanged + HAL keep-alive ([f9e19a0](https://github.com/lsjoberg/lurar/commit/f9e19a051573ec118ad6d0b83dd258e013c2643f))
* **launch:** apply selected preset at autostart, not on first menu open ([97ffb14](https://github.com/lsjoberg/lurar/commit/97ffb1471abdf3fe5f405f08dfb1542902aab12c))
* **release:** let feat commits bump minor in pre-1.0 ([7469c6f](https://github.com/lsjoberg/lurar/commit/7469c6fd4c83a1e0cb3fa6b1457084eaf269c1a7))

## [0.2.3](https://github.com/lsjoberg/lurar/compare/v0.2.2...v0.2.3) (2026-05-18)


### Features

* **editor:** include parent source in the "Derived from" chip ([3e90a5d](https://github.com/lsjoberg/lurar/commit/3e90a5de2901d95f04f9b21f2f71d8e61a363655))
* **settings:** open Settings as a regular Window in the dock ([b028de8](https://github.com/lsjoberg/lurar/commit/b028de875027909207f5f15d46ee9ffe146b427b))
* **ui:** keyboard shortcuts + tooltips throughout, with ⌘/ cheat sheet ([d186c42](https://github.com/lsjoberg/lurar/commit/d186c4275dbdb36961ed687ea3a2c541898a09f4))


### Bug Fixes

* collapse oversized wide-feature cards on mobile ([161d42e](https://github.com/lsjoberg/lurar/commit/161d42e1e3c4eebbed619e88d15b9f669d39ac27))
* **eq:** use peaking-Q alpha for shelves so audio matches AutoEq + on-screen curve ([f995893](https://github.com/lsjoberg/lurar/commit/f995893330ba519c7b2310331b0f03457008aeb3))

## [0.2.2](https://github.com/lsjoberg/lurar/compare/v0.2.1...v0.2.2) (2026-05-17)


### Features

* **app:** show Lurar in the dock while a window is open ([9abb7da](https://github.com/lsjoberg/lurar/commit/9abb7da48558d10179825565736534324c90f98b))
* **editor:** channel-strip layout with drag-on-curve frequency ([63429ed](https://github.com/lsjoberg/lurar/commit/63429ed7c609da7816094a1165cf437d91e8d48b))
* **presets:** merge local + iCloud libraries when enabling sync on a second Mac ([f8980db](https://github.com/lsjoberg/lurar/commit/f8980dbc510dbb291a15f47cbfedc9d36978d274))


### Bug Fixes

* **presets:** replace non-existent NSFileCoordinator two-read API with sequential reads ([291c828](https://github.com/lsjoberg/lurar/commit/291c8288496cf1a8ab8cbf75bb3999a96fa1beaf))

## [0.2.1](https://github.com/lsjoberg/lurar/compare/v0.2.0...v0.2.1) (2026-05-17)


### Features

* **audio:** nudge when macOS default output changes mid-session ([612aca0](https://github.com/lsjoberg/lurar/commit/612aca09a96d5698ee3d7ff2f01cb4d0d05b3ccf))

## [0.2.0](https://github.com/lsjoberg/lurar/compare/v0.1.4...v0.2.0) (2026-05-17)


### ⚠ BREAKING CHANGES

* bundle identifier changes from se.linus.klang to app.lurar.Lurar. macOS treats the renamed binary as a new app — no existing installs to migrate, so TCC permissions reset, user defaults orphan, and preset libraries at `~/Library/Application Support/Klang/` are not carried over. The iCloud container was never registered with Apple, so no migration there either.

### Features

* auto-check permission and start engine on launch ([cc662b5](https://github.com/lsjoberg/lurar/commit/cc662b575b36bef2cbcaa3959a86ff93c1e9f83c))
* **docs:** add waveform-in-circle favicon ([542b693](https://github.com/lsjoberg/lurar/commit/542b69349122010c198b46fe4c136b8709125e5e))
* **docs:** restructure landing page to sell current features ([964980d](https://github.com/lsjoberg/lurar/commit/964980d0017214d229fae53f5f923691cfb1fa95))
* **menu:** group preset actions under the picker; icon-only bypass ([f22525c](https://github.com/lsjoberg/lurar/commit/f22525c33348a192ca35f54ba66a41dadc88fff1))
* rebrand app from Klang to Lurar ([3619d9d](https://github.com/lsjoberg/lurar/commit/3619d9d7b7f9c4af9cd014332c6b7f16c406be9d))


### Bug Fixes

* **audio:** hide Klang's own aggregate from the output picker ([3a37d95](https://github.com/lsjoberg/lurar/commit/3a37d95fb03ac10d20e34097efbfe8d1480722f5))
* **docs:** stop hero &lt;picture&gt; from 404-ing in dark mode ([502554a](https://github.com/lsjoberg/lurar/commit/502554ac76c0273741c04576b1d543fe795d4a5d))
* **menu:** surface remaining matches and clarify suggestion banner ([ba98011](https://github.com/lsjoberg/lurar/commit/ba980110237da26f73c2a5763d79218350096e74))
* **updater:** skip Sparkle auto-start when SUPublicEDKey is empty ([093db92](https://github.com/lsjoberg/lurar/commit/093db9234b86a1773dde4489a0e6facbe803bfe4))

## [0.1.4](https://github.com/lsjoberg/lurar/compare/v0.1.3...v0.1.4) (2026-05-17)


### Bug Fixes

* **ci:** bump release runner to Xcode 16.2 ([766b909](https://github.com/lsjoberg/lurar/commit/766b909a3a9509eba43f65c368fef5a771f44c57))

## [0.1.3](https://github.com/lsjoberg/lurar/compare/v0.1.2...v0.1.3) (2026-05-17)


### Bug Fixes

* **ci:** use PAT in release-please so downstream workflows fire ([6415703](https://github.com/lsjoberg/lurar/commit/6415703318ff8d44b2190805f99b44cfec151366))

## [0.1.2](https://github.com/lsjoberg/lurar/compare/v0.1.1...v0.1.2) (2026-05-17)


### Features

* add landing page and Sparkle appcast scaffolding ([8b4b884](https://github.com/lsjoberg/lurar/commit/8b4b8842a0a4bce561588a272bc68abe9bf3f5ea))
* integrate Sparkle and prepare project for Developer ID signing ([8b45a51](https://github.com/lsjoberg/lurar/commit/8b45a5103f6582596c7a33295edc856c7e8d0940))


### Bug Fixes

* **ci:** remove invalid secrets context use in step-level if ([ef4e3dc](https://github.com/lsjoberg/lurar/commit/ef4e3dc0c036e5a24c1ea98b8520864ae43e7042))
* **pages:** add .nojekyll to bypass Jekyll on Pages ([ff26098](https://github.com/lsjoberg/lurar/commit/ff26098a6f9b085c9d17582808688d49825f642d))
* **release-please:** drop component prefix from release tags ([173358e](https://github.com/lsjoberg/lurar/commit/173358e1d3abb70e6309b27f00c717eab3b46d25))

## [0.1.1](https://github.com/lsjoberg/lurar/compare/lurar-v0.1.0...lurar-v0.1.1) (2026-05-17)


### Features

* add landing page and Sparkle appcast scaffolding ([8b4b884](https://github.com/lsjoberg/lurar/commit/8b4b8842a0a4bce561588a272bc68abe9bf3f5ea))
* integrate Sparkle and prepare project for Developer ID signing ([8b45a51](https://github.com/lsjoberg/lurar/commit/8b45a5103f6582596c7a33295edc856c7e8d0940))


### Bug Fixes

* **ci:** remove invalid secrets context use in step-level if ([ef4e3dc](https://github.com/lsjoberg/lurar/commit/ef4e3dc0c036e5a24c1ea98b8520864ae43e7042))
* **pages:** add .nojekyll to bypass Jekyll on Pages ([ff26098](https://github.com/lsjoberg/lurar/commit/ff26098a6f9b085c9d17582808688d49825f642d))
