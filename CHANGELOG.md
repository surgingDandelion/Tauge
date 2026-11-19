# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Quick Open lists each host once: the duplicate "· SFTP" row per machine is
  gone, so the list is half as long to walk with `↑`/`↓`. `⌘↩` still opens the
  highlighted host as an SFTP tab, and `⇧⌘T` remains the global host picker.
  The highlight also snaps back onto a real row when typing shrinks the list.

## [1.2.2] — 2026-11-19

### Changed

- Quick Open now keeps a stable viewport while typing, supports reliable mouse and wheel interaction, and preserves selection for filtered results such as `MSA`.
- Added Shift range selection and Ctrl/Command multi-selection. Enter opens selected hosts in a temporary terminal workspace grid, while Command-Enter opens them in a temporary SFTP workspace grid.
- Workspaces can be edited from the start page, workspace header, and workspace tab menu. Host, group, and workspace colors are persisted and shown in the relevant lists and tabs.
- Workspace tabs are included in Command-1 through Command-9 navigation, following the natural tab-strip order. Command-0 returns to the start page.
- Local SFTP browsing now includes a clickable `..` parent-directory row.
- Release notes render Markdown headings, lists, emphasis, links, and code blocks in the update window.
- Credential migration no longer opens the login-keychain password dialog after rebuilding, reinstalling, or re-signing. Current credentials remain in the app-local encrypted vault.
- Improved light terminal ANSI contrast for full-screen CLI tools such as Claude Code.

## [1.2.1] — 2026-11-18

### Changed

- The window chrome is sharper without getting bigger: host addresses, counts,
  and tags use a monospaced face, tags are squared, buttons are custom-drawn
  with a real pressed state, and host cards get a hairline border, a corner
  tick, and a faint dot grid behind the start page. Sidebars, tab strips, and
  the status bar follow the same language, and every layout dimension is
  unchanged.

### Fixed

- Resizing the window now re-wraps the remote shell at the new width. The pty
  size was updated but the ssh child never received `SIGWINCH`, so OpenSSH did
  not forward a window-change and lines containing Chinese kept wrapping at
  the old column count.
- The start page header no longer says "1 workspaces" or "1 hosts"; English
  counts use the singular form, and the last-used label says "yesterday" and
  "Used 1 time" instead of "1 days ago" and "1 times".
- The README screenshot shows the current interface and the credential note
  points at the app's encrypted vault instead of the login Keychain.

## [1.2.0] — 2026-11-18

### Added

- **Quick Open** (`⌘K`): a spotlight-style panel over the window that searches
  hosts, workspaces, and commands at once and ranks them by match quality and
  recent use. `↩` opens the tab and connects, `⌘↩` opens an SFTP tab, and the
  panel stays out of the way while another sheet is up. It replaces the
  command-palette sheet.
- SSH keepalives at the protocol level: every connection sends
  `keepalive@openssh.com` global requests (`ServerAliveInterval`, 30s by
  default) and drops the link only when the peer stops answering, on top of the
  `SO_KEEPALIVE` socket option, which macOS only starts after two idle hours.
  System-`ssh` transfers add `-o ServerAliveInterval` / `ServerAliveCountMax=3`.
- Broken SFTP panes come back on their own: the primary pane reconnects the tab,
  an extra pane rebuilds its own channel, and the refresh button reconnects
  instead of staying disabled.
- The update download reports real progress: a byte-level progress bar, the
  transferred and total size, a smoothed transfer rate, and the remaining time.
  The rate meters frames with an exponential average so the label does not
  jitter, and the bar keeps showing the final sample even when the server sends
  no content length.
- SFTP panes support multi-row selection (`⌘` click, `⇧` click for a range) and
  dragging the whole selection in one gesture; each batch asks the conflict
  question once.
- Credentials live in the app's own folder instead of the login keychain:
  `vault.v1.enc` (AES-256-GCM, `0600`) with its random key in `vault.key`.
  Updates, reinstalls and re-signed builds no longer raise "Tauge wants to use
  your confidential information stored in …". A credential an older build left
  in the keychain is read once, migrated, and never looked up again; an account
  deleted in the app stays deleted.
- Touch ID (or the device password) unlocks the vault once per launch. The
  vault is a file, so without this gate nothing would guard a stored password.
  Settings → Security → `Unlock method` turns it off; it is skipped on Macs
  without a sensor, and a failing sensor opens the vault rather than blocking
  the connection.

### Changed

- The transfer details panel names the host of the pane the transfer came from,
  not the tab's first host, so a multi-pane window shows the right machine.
- Credential storage moved from one keychain item per secret, to one item, to
  the encrypted file vault described above. The keychain is now only a migration
  source, and the settings page says where the vault lives instead of warning
  about ad-hoc signing.
- `scripts/package-release.sh` signs with the local `Tauge Local Signing`
  identity when no Developer ID is available, so Keychain grants such as the
  Termius vault survive local release builds.

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
