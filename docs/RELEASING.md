# Releasing Kawenreel

One-time setup required before `scripts/bundle.sh release --sign|--dist` or `scripts/release.sh` can run.

## Prerequisites (one-time, on the Mac)

1. **Apple Developer Program** — enroll at developer.apple.com ($99/yr). Note your Team ID.
2. **Developer ID Application certificate** — create in Xcode (Settings → Accounts → Manage Certificates) or at developer.apple.com, install in the login keychain.
3. **Notary credentials** — create an app-specific password at appleid.apple.com, then:
   ```bash
   xcrun notarytool store-credentials kawenreel-notary \
     --apple-id <your-apple-id> --team-id <TEAMID>
   ```
4. **Sparkle EdDSA keys** — after the first `swift build`:
   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   Paste the printed public key into `SUPublicEDKey` in `Sources/PalmierPro/Resources/Info.plist`
   (replacing `REPLACE_WITH_YOUR_ED25519_PUBLIC_KEY`). The private key stays in the Mac keychain;
   `sign_update` finds it automatically. Never commit the private key.
5. **Sentry (optional)** — create a project at sentry.io and export `SENTRY_DSN`
   (plus `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT` for dSYM upload).

## Environment

Set in the shell or in `.env.prod` at the repo root (loaded by `bundle.sh` for release builds):

```bash
SIGNING_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)"
NOTARY_PROFILE="kawenreel-notary"   # default
SENTRY_DSN="..."                    # optional; telemetry is a no-op without it
```

## Cutting a release

```bash
scripts/release.sh <version>   # e.g. scripts/release.sh 1.0.0
```

Builds, signs, notarizes, staples, creates the GitHub release on `Ariffkmy/kawenreel`,
and appends the Sparkle item to `appcast.xml`. The repo must be public for the
appcast URL (`https://raw.githubusercontent.com/Ariffkmy/kawenreel/main/appcast.xml`) to resolve.
