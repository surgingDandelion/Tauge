# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.9] — 2026-11-24

### 更新

- Apple 芯片 Mac 上的 Tauge 1.2.7 和 1.2.8 可以通过「Tauge → 检查更新… → 下载并安装」直接升级。
- 正式更新包恢复为 `Tauge-1.2.9.zip`。本版本附带一份内容相同的旧名 ZIP，供 1.2.8 的更新器使用。
- 新版仅支持 Apple 芯片和 macOS 13 Ventura 或更新版本。Intel Mac 请继续使用 v1.2.7，看到更新提示时请勿安装。

## [1.2.8] — 2026-11-23

### 平台支持

- **Tauge 和 `tauge` CLI 仅支持搭载 Apple 芯片（arm64）的 Mac**，需要 macOS 13 Ventura 或更新版本。
- **在 Apple 芯片 Mac 上从旧通用版升级时，需要用 DMG 手动升级一次。** 退出 Tauge，打开 `Tauge-1.2.8.dmg`，把新版 Tauge 拖到「应用程序」并选择替换。之后可继续使用应用内更新。

### 改进

- 起始页的「全部主机」按主机分组显示，子分组标明完整路径，搜索结果沿用分区。
- 工作区窗格标题栏跟随主机自定义色或分组继承色，配色改动会更新已打开的窗格。

### 修复

- 清理 SSH、SFTP、CLI 和部分依赖的 Swift 编译告警，调整事件循环与锁的用法。

## [1.2.7] — 2026-11-22

### 修复

- 修复 SSH 连接到 macOS 的 zsh 时，切换终端标签页后出现多行反白 `%` 的问题。切换时保留终端状态和后台输出，不影响 zsh 正常的提示符和无换行提示。

### 改进

- 编辑主机或代理时，已保存的密码和私钥口令默认隐藏，可点击眼睛图标显示或隐藏。清空凭据或取消保存后，不再使用旧凭据。
- 读取本地加密凭据不再要求 Touch ID 或 Mac 登录密码。旧钥匙串仅用于无提示、只读迁移；无法自动迁移的密码或口令，可在对应配置中重新输入并保存。

## [1.2.6] — 2026-11-20

### Added

- Host colors now follow the closest group color when a machine has no color of
  its own. A machine's own color still wins, and an ungrouped or colorless
  machine no longer falls back to system blue.
- Machine names in the sidebar and on the start page now use the resolved color,
  making the accent visible beyond the tiny icon or color strip.

### Changed

- Group color edits no longer paint every descendant host. Hosts that were only
  mirroring the group color are released so they follow the new color; hosts
  with a distinct color keep it.
- Quick Open lists each host once: the duplicate "· SFTP" row per machine is
  gone, so the list is half as long to walk with `↑`/`↓`. `⌘↩` still opens the
  highlighted host as an SFTP tab, and `⇧⌘T` remains the global host picker.
  The highlight also snaps back onto a real row when typing shrinks the list.

## [1.2.5] — 2026-11-20

### Added

- Group settings can now carry default jump hosts: pick up to three jump hosts on a group, and machines whose jump setting is "Inherit from Group" use the nearest group's choice. A machine's own setting still wins, and proxy and jump hosts stay mutually exclusive.
- The group editor is now a full "Group Settings" sheet reachable from the sidebar and host editor, with inline parent-group editing and cycle protection.

### Fixed

- Universal release packaging no longer fails on the CLI lipo step: the TaugeCLI binary paths are now resolved with the correct component-append pattern, so `lipo` receives the real arm64 and x86_64 binaries instead of their containing directories. This is what blocked the v1.2.4 release.

## [1.2.4] — 2026-11-20

### Added

- Added the Tauge CLI installer and local gateway command service.

### Fixed

- Published a transitional update with the legacy `com.shellx.app` bundle ID so existing installations can update without a Bundle ID mismatch.
- The updater now accepts the one-time migration from `com.shellx.app` to `com.tauge.app` for a later release.

## [1.2.3] — 2026-11-20

### Added

- Renamed the product and package targets from ShellX to Tauge.
- Added command safety confirmations and the local gateway command service.

### Changed

- Parent groups now render machines in separate child-group sections with dividers.
- Group colors can be edited inline and propagate to machines in the group subtree.
- Host card drag ordering uses delayed insertion previews and smooth animation.
- Improved credential vault, workspace, quick-open, terminal, and transfer behavior.

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
