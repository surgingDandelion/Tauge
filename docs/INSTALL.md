# Installing Tauge

Tauge requires **macOS 13 Ventura or later** on Apple silicon or Intel.

## From a release

1. Download `Tauge-<version>.dmg` from the [latest release](https://github.com/surgingDandelion/Tauge/releases/latest).
2. Open the disk image and drag **Tauge** into **Applications**.
3. Eject the disk image and launch Tauge from Applications.

Every release publishes `SHA256SUMS.txt`. To verify a download:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

### If macOS blocks the first launch

Release builds are notarised when the release workflow has Apple Developer ID
credentials configured; in that case the app launches normally. Builds produced
without those credentials are **ad-hoc signed**, and macOS will show one of:

- *“Tauge” cannot be opened because the developer cannot be verified.*
- *“Tauge” is damaged and can’t be opened. You should move it to the Trash.*

These messages describe an unnotarised build, not a corrupt download. If you
trust the source and the checksum, either:

**Option A — allow it in System Settings**

Open **System Settings → Privacy & Security**, scroll down, click **Open
Anyway** next to the Tauge notice, then confirm. macOS remembers the choice for
that exact build.

**Option B — remove the quarantine flag**

```bash
xattr -dr com.apple.quarantine /Applications/Tauge.app
```

Do not disable Gatekeeper globally. Only apply this to a build whose checksum
you verified.

### Updating

Replace `/Applications/Tauge.app` with the new copy. Hosts, groups, settings,
and transfer history live outside the bundle (see below) and are preserved.
After an update signed by a different certificate, macOS may ask once for
Keychain access again; choose **Always Allow**.

## Build from source

Requirements: macOS 13+, Command Line Tools (`xcode-select --install`), and
network access the first time SwiftPM resolves dependencies.

```bash
git clone https://github.com/surgingDandelion/Tauge.git
cd Tauge

export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache"

swift build --disable-sandbox
./scripts/build-app.sh release
open dist/Tauge.app
```

`--disable-sandbox` is only required when `sandbox-exec` is unavailable in
the build environment (for example inside another sandbox). A normal Terminal
session can omit it.

For a universal build:

```bash
TAUGE_ARCHS="arm64 x86_64" ./scripts/build-app.sh release
```

Create a DMG, ZIP, and checksums with:

```bash
./scripts/package-release.sh
```

## Signing for distribution

A seamless first launch requires an Apple Developer ID Application certificate
and notarisation. To produce a signed build locally:

```bash
export TAUGE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export TAUGE_SIGN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
export TAUGE_NOTARY_APPLE_ID="you@example.com"
export TAUGE_NOTARY_TEAM_ID="TEAMID"
export TAUGE_NOTARY_PASSWORD="app-specific-password"
./scripts/package-release.sh
```

The GitHub release workflow can do this automatically when these repository
secrets are configured:

| Secret | Purpose |
| ------ | ------- |
| `MACOS_CERT_P12_BASE64` | Base64 of the exported Developer ID `.p12` |
| `MACOS_CERT_PASSWORD` | Password of the `.p12` |
| `KEYCHAIN_PASSWORD` | Any temporary password for the CI keychain |
| `APPLE_ID` | Apple ID used for notarisation |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |

Without them the workflow still builds and publishes artifacts, but macOS will
require the manual approval described above.

For local development, `./scripts/setup-signing.sh` creates a self-signed
certificate so that Keychain “Always Allow” grants survive rebuilds.

## Uninstalling

1. Quit Tauge and move `/Applications/Tauge.app` to the Trash.
2. Optionally remove application data:

```bash
rm -rf "$HOME/Library/Application Support/ShellX"
rm -rf "$HOME/Logs"
security delete-generic-password -s shellx   # repeat for each stored credential
```

The data directory keeps the historical `ShellX` name so that upgrades from
the project's earlier internal name do not lose hosts or settings.
