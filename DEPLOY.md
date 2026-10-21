# Deploying Sconeos on Vercel (`sconeos.gattey.com`)

## Connect the GitHub repo

1. Push this repository (`dgattey/scone-os`) to GitHub.
2. In Vercel (`dylan-gattey` scope): **Add New Project** → import `dgattey/scone-os` as `scone-os`.
3. Set **Root Directory** to `server` (required; the Next.js download site lives there).
4. Framework preset detects **Next.js** automatically.
5. Add custom domain **`sconeos.gattey.com`** (and redirect `scone-os.vercel.app` → `sconeos.gattey.com`).

Vercel only deploys `server/` when root directory is set. Leave **Include files outside the Root Directory in the Build Step** on (the default): the site installs `@dylkit/web` from `../Packages/DylKit/web` and reads `../DylApp.toml` at build time.

`server/vercel.json`'s `ignoreCommand` skips deploys for commits that touch none of `server/`, `Packages/DylKit/web` or `DylApp.toml`, so app-only merges don't spend the deploy quota. `release-kit check` (`site_deploy`) fails if it would ever skip a release commit.

macOS Sparkle files (`appcast.xml` and `Sconeos-<version>.zip`) in `server/public/` are committed by `.github/workflows/release.yml` when the app changes on `main`. Vercel’s normal Git Production deploy serves them at `https://sconeos.gattey.com/appcast.xml` and `https://sconeos.gattey.com/download/macos`.

## How auto-updates & signing work

- Small household install: **ad-hoc** code signing (`-`) + `com.apple.security.cs.disable-library-validation` (`Sconeos.local.entitlements`) + Sparkle 2 EdDSA. No Apple Developer Program required.
- Ad-hoc signing (`-`) with `com.apple.security.cs.disable-library-validation` works cleanly with macOS Gatekeeper's **Privacy & Security → Open Anyway** flow (whereas untrusted self-signed X.509 certificates get killed by `syspolicyd`/`amfid` on macOS Sequoia/Tahoe when quarantined).
- Sparkle 2 validates and installs updates via the EdDSA signature (`SUPublicEDKey` in `Info.plist` + `sparkle:edSignature` in `appcast.xml`; the key pair comes from `scripts/generate-sparkle-key.sh`).
- The macOS app checks `https://sconeos.gattey.com/appcast.xml` (Sparkle 2, EdDSA signed).
- When a push or merge to `main` touches `[release] inputs` in `DylApp.toml`, `.github/workflows/release.yml` runs that release, one at a time. Each step is one `./run release` command. `.cursor/skills/apple-release/SKILL.md` lists the steps. `./run release --help` lists the commands.
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
