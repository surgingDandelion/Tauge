# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.2] — 2026-11-18

### Added

- Added `scripts/release.sh`, a one-command release flow that verifies the
  repository state, runs the localisation and self-check suites, bumps the
  version, updates `CHANGELOG.md`, pushes the tag, waits for GitHub Actions,
  and verifies the published assets.

### Changed

- GitHub Release pages now use the matching `CHANGELOG.md` section as their
  "What's changed" text instead of a fixed install template.

## [1.1.1] — 2026-11-18

### Fixed

- A successful update now removes the hidden backup copy of the previous app
  instead of leaving roughly 50 MB next to Tauge after every release. If the new
  bundle fails to launch, the installer restores the backup automatically.

## [1.1.0] — 2026-11-18

### Added

- In-app updates driven by GitHub tags and releases. Tauge checks the latest
  stable release, compares semantic versions, shows the release notes, downloads
  `Tauge-<version>.zip`, verifies it against the release's `SHA256SUMS.txt`,
  validates the new bundle's identifier, version, and code signature, then
  replaces the app after it quits and relaunches it.
- **Tauge → Check for Updates…**, a daily background check that can be disabled
  in Settings → General, and a dedicated update window with progress,
  cancellation, retry, and a link to the release on GitHub.
- The About pane now reports the real bundle version and build number and can
  start an update check.

### Notes

- An app launched directly from the disk image or another read-only location
  cannot update itself; move it to Applications first.
- Installing into `/Applications` normally needs no administrator password. If
  the destination is owned by another user, macOS asks for authorisation once.

## [1.0.1] — 2026-11-18

### Fixed

- The packaged app no longer crashes at launch when SwiftPM emits a flat
  resource bundle. `TaugeL10n` now looks for `en.json` directly in both the
  flat and `Contents/Resources` layouts instead of using `Bundle.module`, whose
  search path differs between SwiftPM toolchains.
- `scripts/build-app.sh` now loads the packaged localisation table
  (`Tauge --verify-localization`) before declaring the bundle ready, and CI
  verifies the same thing after assembling the app.

## [1.0.0] — 2026-11-18

First public release of Tauge, a local-first macOS SSH/SFTP client.

### Added

- Host and group management with unlimited nesting, inherited group defaults,
  drag-and-drop ordering, favourites, recent hosts, and pinyin-initial search.
- Terminal sessions on SwiftTerm: tabs, split-pane workspaces, incremental
  search, copy-on-select, paste confirmation, six colour themes, scrollback,
  session logging, and automatic reconnection with backoff.
- Workspaces (boards): multi-pane grids, manual split/swap with live snap
  guides, per-pane SFTP, persisted layouts, and deferred-save indicators.
- Standalone SFTP tabs and panels: local + multiple remote panes, server-to-
  server relay transfers, per-host directory history, built-in editor, chmod,
  rename, delete, and recursive upload/download.
- Transfer engine with 1–4 concurrent transfers, resumable chunks, retries,
  pause/resume/cancel, conflict policies, and a transfer centre.
- Authentication with passwords and Ed25519/ECDSA/RSA private keys, Keychain-
  backed credential storage, and TOFU host-key verification with SHA-256
  fingerprints.
- Jump hosts (up to three hops) and HTTP CONNECT / SOCKS5 proxies with
  host → group → global scopes.
- Importers for `~/.ssh/config` and Termius vaults (decrypted locally with the
  Termius Keychain key; no network access).
- English and Simplified Chinese localisation with a live language switch.
- Command palette (`⌘K`), menu-bar extra, start page, and single-instance
  window lifecycle.

### Notes

- Release builds are ad-hoc signed unless Developer ID credentials are
  configured for the release workflow. See [docs/INSTALL.md](docs/INSTALL.md)
  if macOS blocks the first launch.
- Tauge was previously developed under the internal name ShellX. The bundle
  identifier, Keychain service names, and data directory keep the `shellx`
  identifier so upgrades never lose data.
