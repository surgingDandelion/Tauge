# Installing Tauge

Tauge requires **macOS 13 Ventura or later** on Apple silicon or Intel.

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

Tauge updates itself. It checks GitHub releases once a day in the background,
and **Tauge → Check for Updates…** runs a check immediately. When a newer
version exists, the update window shows its release notes; **Download and
Install** fetches `Tauge-<version>.zip`, verifies it against the release's
`SHA256SUMS.txt`, validates the new bundle, then quits, swaps the app in place,
and relaunches it. No administrator password is normally required for
`/Applications`.

An app running from the disk image, a read-only volume, or a quarantined
translocated path cannot update itself. Move it to Applications first.

To update by hand instead, quit Tauge, replace `/Applications/Tauge.app` with
the copy from the newer disk image, and launch it again. Hosts, groups,
settings, and transfer history live outside the bundle (see below) and are
preserved in both paths. After an update signed by a different certificate,
macOS may ask once for Keychain access again; choose **Always Allow**.

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
