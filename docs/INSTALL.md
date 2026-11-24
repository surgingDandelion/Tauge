# Installing Tauge

New Tauge releases require a Mac with **Apple silicon (`arm64`)** running
**macOS 13 Ventura or later**. Intel Macs should stay on Tauge 1.2.7.

## From a release

1. Download `Tauge-<version>.dmg` from the [latest release](https://github.com/surgingDandelion/Tauge/releases/latest).
2. Open the disk image and drag **Tauge** into **Applications**.
3. Eject the disk image and launch Tauge from Applications.

Every release publishes `SHA256SUMS.txt`. The updater checks it
automatically; to verify a download by hand:

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

On Apple silicon, Tauge checks GitHub releases once a day in the background, and
**Tauge → Check for Updates…** runs a check immediately. When a newer version is
available, the update window shows its release notes. **Download and Install**
fetches `Tauge-<version>.zip`, verifies it against the release's
`SHA256SUMS.txt`, validates the new bundle, then quits, swaps the app in place,
and relaunches it. No administrator password is normally required for
`/Applications`.

An app running from the disk image, a read-only volume, or a quarantined
translocated path cannot update itself. Move it to Applications first.

To update by hand instead, quit Tauge, replace `/Applications/Tauge.app` with
the copy from the newer disk image, and launch it again. Hosts, groups,
settings, and transfer history live outside the bundle (see below) and are
preserved in both paths. Saved credentials are unaffected by a new signature:
they live in the app's own encrypted vault, not in the login keychain, so an
update or re-signed build does not raise a Keychain prompt.

The vault is `vault.v1.enc` with its random key in `vault.key`, both in
Application Support and readable only by your user (`0600`). The key is a local
file, so Tauge does not ask for Touch ID or the Mac login password to read it.
Keep both files private: anyone who can read both can decrypt the vault.
An older credential is migrated when macOS can read it without authorization.
If its old signature grant is no longer valid, Tauge skips it without showing a
login-keychain password dialog. Re-enter the password or passphrase once in
the corresponding configuration to save it in the local vault.

## Build from source

Build on an Apple silicon Mac running macOS 13 or later with the Command Line
Tools (`xcode-select --install`). SwiftPM needs network access the first time
it resolves dependencies.

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
certificate so that macOS keeps recognising the app across rebuilds.
`./scripts/build-app.sh` and `./scripts/package-release.sh` both use that
identity by default when it is installed, and only fall back to an ad-hoc
signature otherwise — an ad-hoc signature pins the cdhash, which changes on
every build, so any keychain grant (reading the Termius vault, for example) has
to be confirmed again. Saved credentials are unaffected: they live in the app's
own `vault.v1.enc`, not in a keychain item.

## Uninstalling

1. Quit Tauge and move `/Applications/Tauge.app` to the Trash.
2. Optionally remove application data:

```bash
rm -rf "$HOME/Library/Application Support/Tauge"
rm -rf "$HOME/Logs"
# Older builds kept credentials in the login keychain; this removes the legacy item.
security delete-generic-password -s com.tauge.credentials 2>/dev/null || true
```

The data directory keeps the historical `Tauge` name so that upgrades from
the project's earlier internal name do not lose hosts or settings.
