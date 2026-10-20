# Deploying Sconeos on Vercel (`sconeos.gattey.com`)

## Connect the GitHub repo

1. Push this repository (`dgattey/scone-os`) to GitHub.
2. In Vercel (`dylan-gattey` scope): **Add New Project** → import `dgattey/scone-os` as `scone-os`.
3. Set **Root Directory** to `server` (required; the Next.js download site lives there).
4. Framework preset detects **Next.js** automatically.
5. Add custom domain **`sconeos.gattey.com`** (and redirect `scone-os.vercel.app` → `sconeos.gattey.com`).

Vercel only deploys `server/` when root directory is set. Leave **Include files outside the Root Directory in the Build Step** on (the default): the site installs `@dylkit/web` from `../Packages/DylKit/web` and reads `../DylApp.toml` at build time.

macOS Sparkle files (`appcast.xml` and `Sconeos-<version>.zip`) in `server/public/` are committed by `.github/workflows/release.yml` when the app changes on `main`. Vercel’s normal Git Production deploy serves them at `https://sconeos.gattey.com/appcast.xml` and `https://sconeos.gattey.com/download/macos`.

## How auto-updates & signing work

- Small household install: **ad-hoc** code signing (`-`) + `com.apple.security.cs.disable-library-validation` (`Sconeos.local.entitlements`) + Sparkle 2 EdDSA. No Apple Developer Program required.
- Ad-hoc signing (`-`) with `com.apple.security.cs.disable-library-validation` works cleanly with macOS Gatekeeper's **Privacy & Security → Open Anyway** flow (whereas untrusted self-signed X.509 certificates get killed by `syspolicyd`/`amfid` on macOS Sequoia/Tahoe when quarantined).
- Sparkle 2 validates and installs updates via the EdDSA signature (`SUPublicEDKey` in `Info.plist` + `sparkle:edSignature` in `appcast.xml`; the key pair comes from `scripts/generate-sparkle-key.sh`).
- The macOS app checks `https://sconeos.gattey.com/appcast.xml` (Sparkle 2, EdDSA signed).
- Push/merge to **`main`** touching a release input (`[release] inputs` in `DylApp.toml`) runs `.github/workflows/release.yml`, one release at a time. Each step is one `./run release` command, so any CI can run the same release:
  1. `version` reads the `# Release info` checkbox (`Major` / `Minor` / `Patch`, exactly one) and notes from the merged PR's body, the latest version from git tags and the appcasts, and raises the build number above the live feed's. The body comes from `ci/github/pr-body.sh`, the one GitHub-specific step (a `curl` to the commit's pulls API with `GITHUB_TOKEN`); if that lookup fails, `version` reads the merge commit message, and it fails the release if neither checks exactly one box.
  2. `bundle` and `sign` build and ad-hoc sign `Sconeos.app` in `build/release/`.
  3. `appcast` writes cumulative notes, runs Sparkle's `generate_appcast`, verifies the new `sparkle:edSignature` against `SUPublicEDKey` in the built app (failing closed), and installs `server/public/appcast.xml` and `server/public/Sconeos-<version>.zip`.
  4. `check` runs the release checks, `publish` commits `server/public/`, tags `v<version>` and pushes both with plain git.
  5. An ubuntu job waits up to 15 minutes for `https://sconeos.gattey.com/appcast.xml` and the download page to show the new version. `./run release check --live` on a Mac also verifies the live zip's signature.
- Sparkle only renders the winning appcast item's `<description>`, so `release-kit` bakes the new version's notes plus the previous 9 versions (from the committed and live appcasts) into it. Preview them with `./run release notes --body-file <pr-body.md>`.
- That release commit only touches `server/public/**`, so the workflow does **not** run again (no loop). Vercel's Git integration deploys the updated `server/public/` automatically.

## GitHub Actions secrets

Push the Sparkle EdDSA signing secret:

```bash
./scripts/export-ci-secrets.sh
```

| Secret | Purpose |
|--------|---------|
| `SPARKLE_ED_PRIVATE_KEY_BASE64` | Sparkle EdDSA private key for signing release archives in `appcast.xml` |
