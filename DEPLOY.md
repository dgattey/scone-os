# Deploying Sconeos on Vercel (`sconeos.gattey.com`)

## Connect the GitHub repo

1. Push this repository (`dgattey/scone-os`) to GitHub.
2. In Vercel (`dylan-gattey` scope): **Add New Project** → import `dgattey/scone-os` as `scone-os`.
3. Set **Root Directory** to `server` (required; the Next.js download site lives there).
4. Framework preset detects **Next.js** automatically.
5. Add custom domain **`sconeos.gattey.com`** (and redirect `scone-os.vercel.app` → `sconeos.gattey.com`).

Vercel only deploys `server/` when root directory is set.

macOS Sparkle files (`appcast.xml` and `Sconeos-<version>.zip`) in `server/public/` are committed by `.github/workflows/release-macos.yml` when the app changes on `main`. Vercel’s normal Git Production deploy serves them at `https://sconeos.gattey.com/appcast.xml` and `https://sconeos.gattey.com/download/macos`.

## How auto-updates work

- The macOS app checks `https://sconeos.gattey.com/appcast.xml` (Sparkle 2, EdDSA signed).
- Push/merge to **`main`** with macOS app changes → `.github/workflows/release-macos.yml` reads the merged PR's `# Release info` checkbox (`Major` / `Minor` / `Patch`), builds & signs `Sconeos.app`, updates `server/public/appcast.xml` and `server/public/Sconeos-<version>.zip`, commits `server/public/` + `VERSION`, pushes to `main`, and creates a GitHub Release.
- That release commit only touches `server/public/**` and `VERSION`, so the workflow does **not** run again (no loop). Vercel’s Git integration deploys the updated `server/public/` automatically.

## GitHub Actions secrets

Push signing secrets from the local `.cert/` and Sparkle EdDSA key:

```bash
./scripts/export-ci-secrets.sh
```

| Secret | Purpose |
|--------|---------|
| `SCONEOS_CODESIGN_P12_BASE64` | Self-signed `.p12` from `.cert/sconeos.p12` |
| `SCONEOS_CODESIGN_P12_PASSWORD` | P12 password (default `sconeos`) |
| `SPARKLE_ED_PRIVATE_KEY_BASE64` | Sparkle EdDSA private key |
