# Deploying Sconeos on Vercel (`sconeos.gattey.com`)

## Connect the GitHub repo

1. Push this repository (`dgattey/scone-os`) to GitHub.
2. In Vercel (`dylan-gattey` scope): **Add New Project** → import `dgattey/scone-os` as `scone-os`.
3. Set **Root Directory** to `server` (required; the Next.js download site lives there).
4. Framework preset detects **Next.js** automatically.
5. Add custom domain **`sconeos.gattey.com`** (and redirect `scone-os.vercel.app` → `sconeos.gattey.com`).

Vercel only deploys `server/` when root directory is set. Leave **Include files outside the Root Directory in the Build Step** on (the default): the site reads `../DylApp.toml` at build time. It installs `@dylkit/web` from the tarball on the matching [DylKit release](https://github.com/dgattey/dyl-kit/releases).

`server/vercel.json`'s `ignoreCommand` skips deploys for commits that touch neither `server/` nor `DylApp.toml` since the last deployed commit, so app-only merges don't spend the deploy quota.

Releases live in the public Vercel Blob store that `[release] assets` in `DylApp.toml` names. The site serves its newest `appcast.xml`, the `/download/macos` redirect to its zip, and the icons each release renders from the app icon. Nothing is committed for a release.

## How auto-updates & signing work

- Small household install: **ad-hoc** code signing (`-`) + `com.apple.security.cs.disable-library-validation` (`Sconeos.local.entitlements`) + Sparkle 2 EdDSA. No Apple Developer Program required.
- Ad-hoc signing (`-`) with `com.apple.security.cs.disable-library-validation` works cleanly with macOS Gatekeeper's **Privacy & Security → Open Anyway** flow (whereas untrusted self-signed X.509 certificates get killed by `syspolicyd`/`amfid` on macOS Sequoia/Tahoe when quarantined).
- Sparkle 2 validates and installs updates via the EdDSA signature (`SUPublicEDKey` in `Info.plist` + `sparkle:edSignature` in `appcast.xml`; the key pair comes from `scripts/generate-sparkle-key.sh`).
- The macOS app checks `https://sconeos.gattey.com/appcast.xml` (Sparkle 2, EdDSA signed).
- When a PR that changes the app merges to `main`, `.github/workflows/dylkit.yml` releases it through DylKit's reusable `app.yml` workflow, one at a time: it tags the merge commit and uploads the zip, icons, `appcast.xml` and `release.json` to the Blob store. Each step is one `swift run release-kit` command. The DylKit plugin's `apple-release` skill lists the steps. `swift run release-kit --help` lists the commands.
- Sparkle only renders the winning appcast item's `<description>`, so `release-kit` bakes the new version's notes plus the previous 9 versions (from the published feeds) into it. Preview them with `swift run release-kit notes --body-file <pr-body.md>`.

## GitHub Actions secrets

Push the Sparkle EdDSA signing secret:

```bash
./scripts/export-ci-secrets.sh
```

| Secret | Purpose |
|--------|---------|
| `SPARKLE_ED_PRIVATE_KEY_BASE64` | Sparkle EdDSA private key for signing release archives in `appcast.xml` |
| `BLOB_READ_WRITE_TOKEN` | Uploads each release to the Blob store; the DylKit plugin's `adopt-dylkit` skill shows where to copy it |
