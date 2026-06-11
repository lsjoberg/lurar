# Homebrew distribution for Lurar

`lurar.rb` in this folder is a ready-to-use Homebrew **cask** (DMG installer). There are two
ways to make `brew install` work; they are not mutually exclusive.

## Route A — your own tap (works today, recommended for now)

A "tap" is just a public GitHub repo named `homebrew-<something>` containing a `Casks/` folder.
No notability requirements, fully under your control, no review queue.

1. Create a new public repo **`lsjoberg/homebrew-lurar`** on GitHub.
2. Put this cask in it at `Casks/lurar.rb` (copy from `packaging/homebrew/lurar.rb`):

   ```bash
   git clone https://github.com/lsjoberg/homebrew-lurar
   mkdir -p homebrew-lurar/Casks
   cp packaging/homebrew/lurar.rb homebrew-lurar/Casks/lurar.rb
   cd homebrew-lurar && git add Casks/lurar.rb && git commit -m "lurar 0.9.1" && git push
   ```

3. Users install with either of:

   ```bash
   brew install --cask lsjoberg/lurar/lurar
   # or
   brew tap lsjoberg/lurar && brew install --cask lurar
   ```

Verify locally before pushing:

```bash
brew install --cask ./packaging/homebrew/lurar.rb   # installs from the local file
brew audit --cask --new ./packaging/homebrew/lurar.rb
brew uninstall --cask lurar
```

### Keep the tap current automatically

Sparkle auto-updates already-installed copies, so the only thing that goes stale is the cask's
`version` + `sha256` for *new* installs. This is now handled by the **"Bump Homebrew cask"** step
in `.github/workflows/release.yml`: on every tagged release it hashes the freshly built
`build/Lurar-<version>.dmg`, rewrites `Casks/lurar.rb` in this tap, and pushes it to `main`.

The step needs a PAT with push access to `lsjoberg/homebrew-lurar`, exposed as the repo secret
**`HOMEBREW_TAP_TOKEN`** (it falls back to `RELEASE_PLEASE_TOKEN` if that is a classic token with
`repo` scope). Create a fine-grained PAT scoped to `homebrew-lurar` with **Contents: read/write**
and add it under *lurar → Settings → Secrets and variables → Actions*.

## Route B — the official `homebrew/cask` repo (later, when notable)

Lets users run plain `brew install --cask lurar` with no tap. Requires a PR to
`Homebrew/homebrew-cask` adding `Casks/l/lurar.rb`, and the repo must clear the **notability**
bar. As of 2026 (Homebrew docs, "Acceptable Casks"):

- Third-party submission: rejected if the GitHub repo has < 30 forks / < 30 watchers / < 75 stars.
- **Self-submission (you, the repo owner): 3× higher — needs ≥ 90 forks, ≥ 90 watchers, or ≥ 225 stars.**

At v0.9.1 you almost certainly don't clear the self-submission bar yet, so start with Route A.
Once Lurar has the stars (ideally let a *third party* open the PR once you pass 75), submit to
the official repo and keep the tap as a fallback. The `livecheck` block already lets Homebrew's
autobump bot track new releases via your Sparkle appcast.
