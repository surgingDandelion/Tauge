# Tauge

**A local-first SSH and SFTP client for macOS.** Native SwiftUI, split-pane
workspaces, multi-server SFTP with server-to-server transfers, and credentials
that never leave your Mac.

[![CI](https://github.com/surgingDandelion/Tauge/actions/workflows/ci.yml/badge.svg)](https://github.com/surgingDandelion/Tauge/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/surgingDandelion/Tauge?display_name=tag)](https://github.com/surgingDandelion/Tauge/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-black)](https://www.apple.com/macos/)

English · [简体中文](README.zh-CN.md)

Tauge is built with SwiftPM only — SwiftUI, AppKit, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
and a vendored fork of [SwiftNIO SSH](Vendor/swift-nio-ssh). There is no
account, no sync service, and no telemetry. Hosts, keys, and transfer history
live in a local SQLite database; secrets live in the macOS Keychain.

> Tauge was previously developed under the internal name **ShellX**. The bundle
> identifier, Keychain service names, and data directory keep the `shellx`
> identifier, so upgrades never lose data.

![Tauge start page: hosts grouped by project, with tags and last-used state](docs/images/start-page.png)

## Install

Download the latest `Tauge-<version>.dmg` from
[Releases](https://github.com/surgingDandelion/Tauge/releases/latest), drag
Tauge into Applications, and launch it.

If macOS refuses the first launch, follow
[docs/INSTALL.md](docs/INSTALL.md#if-macos-blocks-the-first-launch). Release
builds are notarised when the release workflow has Developer ID credentials;
otherwise they are ad-hoc signed and need a one-time approval.

Requires macOS 13 Ventura or later (Apple silicon or Intel).

Tauge updates itself from GitHub releases. It checks once a day in the
background, shows the release notes of a newer tag, verifies the download's
SHA-256 checksum, and swaps the app in place after quitting. Use **Tauge →
Check for Updates…** to check immediately. The app must live in a writable
location such as `/Applications`; an app launched straight from the disk image
cannot update itself.

## Features

### Hosts and groups

- Unlimited nested groups with inheritable defaults for user, port, key,
  proxy, jump hosts, terminal theme, and encoding.
- Drag-and-drop ordering and moving between groups; favourites and the 20 most
  recent hosts; search across names, addresses, users, tags, notes, and pinyin
  initials.
- Import `~/.ssh/config` (Host, HostName, User, Port, IdentityFile,
  ProxyJump) or a Termius vault. Termius data is decrypted locally with the
  `localKey` from your Keychain — the vault never leaves the machine — with a
  preview, endpoint deduplication, and optional import of unsaved hosts from
  connection history.

### Terminal

- SwiftTerm-based xterm-256color terminal with true colour, mouse reporting,
  bracketed paste, OSC 8 hyperlinks, and OSC 52 clipboard.
- Tabs with `⌘T`, `⌘W`, `⌘1…9`, drag reordering, incremental find (`⌘F`),
  copy-on-select, right-click paste, multi-line paste confirmation, and
  Option-as-Meta.
- Six colour themes, configurable font, size, line height, and opacity, with
  10,000 lines of scrollback.
- Disconnects keep the screen contents and reconnect with exponential backoff.
- Optional session logging to `~/Logs/<host>/<date>.log`, with redaction.

### Workspaces

- A workspace is one tab containing a grid of SSH panes; each pane is an
  independent session with its own find bar, SFTP browser, drop target, log,
  and reconnect behaviour.
- Drag a pane title onto another pane’s edge to split; drag onto its centre to
  swap. Splitters snap to 25/33/50/67/75%, reset on double-click, and show live
  guides. Double-click a title to maximise a pane.
- New-workspace sheet with layout choice and multi-select of servers by group.
- Layouts, open panes, and per-pane SFTP state persist across launches. Pane
  edits are staged until you save (`⌘S`) or leave the workspace.

### SFTP and transfers

- Local pane plus any number of remote panes; the primary pane reuses the
  terminal’s SSH connection, extra panes open their own.
- Drag between two remote panes to relay server-to-server without touching the
  local disk. Drag to Finder to download; drop Finder files to upload.
- Path bars with `~` and relative paths, back/forward/up, hidden files, and
  per-host history of the last 50 directories.
- Built-in editor for files under 2 MB, chmod, rename, delete, and directory
  creation.
- Transfer engine with 1–4 concurrent transfers, 32 KiB chunks, resumable
  downloads, three retries, pause/resume/cancel, and conflict policies
  (overwrite, skip, rename, newer-only).
- Transfer centre with persisted history and a global progress overlay that
  stays visible outside the SFTP panes.

### Updates

- In-app updates driven by GitHub tags and releases: checks the latest stable
  release, compares semantic versions, and shows the release notes before
  installing.
- Downloads `Tauge-<version>.zip`, verifies it against the release's
  `SHA256SUMS.txt`, validates the new bundle's identifier, version, and code
  signature, then replaces the app after it quits and relaunches it.
- Daily background check (configurable in Settings → General), a manual
  **Check for Updates…** item in the app menu, and progress, retry, and
  cancellation in a dedicated window.

### Security and connectivity

- Password or private-key authentication: Ed25519, ECDSA P-256/P-384/P-521,
  and RSA in OpenSSH, PKCS#8, or SEC1 format (unencrypted PEM only).
- Passwords and key passphrases are stored in the Keychain with
  `kSecAttrAccessibleAfterFirstUnlock`; the database contains no plaintext
  secrets.
- Trust-on-first-use host-key verification with SHA-256 and MD5 fingerprints;
  changed keys are blocked and the old and new fingerprints are shown side by
  side.
- Up to three jump hosts using `direct-tcpip`, with per-hop credentials or
  reuse of the target credentials.
- HTTP CONNECT (Basic) and SOCKS5/SOCKS5h (RFC 1929) proxies, scoped per host,
  per group, or globally (host &gt; group &gt; global).

### Interface

- Start page with workspaces/groups on the left and draggable host cards on the
  right; a hideable sidebar; status bar with route, encoding, and transfer
  speed.
- Command palette (`⌘K`) with the group tree, workspaces, and commands.
- Menu-bar extra for opening the window, new terminal/SFTP tabs, the command
  palette, and the transfer centre.
- Single instance; closing the main window quits the process cleanly.
- English and Simplified Chinese, switchable at runtime in Settings → General.

## Build from source

Requirements: macOS 13+, Command Line Tools (`xcode-select --install`), and
network access for the first dependency resolution. The project is developed
with Swift 6.4 on macOS 26 and targets macOS 13.

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

`--disable-sandbox` is only needed where `sandbox-exec` is restricted (for
example when building inside another sandbox). The Command Line Tools SDK does
not ship SwiftUI’s macro plugin, so the UI uses equivalent property wrappers in
[`Sources/ShellXApp/ViewState.swift`](Sources/ShellXApp/ViewState.swift).

Universal build:

```bash
TAUGE_ARCHS="arm64 x86_64" ./scripts/build-app.sh release
```

## Self-checks

The Command Line Tools toolchain ships neither XCTest nor swift-testing, so the
suite is an executable target:

```bash
swift run --disable-sandbox ShellXChecks
```

It currently runs **over 2,000 checks**, including SFTP v3 codec round trips,
`ssh_config` parsing (OpenSSH first-value-wins semantics), group inheritance
and jump chains, workspace split-tree maths, transfer-engine behaviour
(resume, recursion, conflicts, progress), RSA key parsing against `ssh-keygen`
fingerprints, XSalsa20-Poly1305 vectors, localisation table integrity, and
end-to-end SSH against an in-process mock server (handshake, public-key auth,
PTY shell, SFTP subsystem, `rsa-sha2-256/512`, and one- and two-hop
`direct-tcpip` tunnels).

Optional live checks are skipped unless their environment variables are set:
`SHELLX_LIVE_SSH`, `SHELLX_REAL_JUMP`, `SHELLX_REAL_TRANSFER`, and
`SHELLX_TERMIUS` (see the README of the checks in
[`Sources/ShellXChecks`](Sources/ShellXChecks)).

## Signing and notarisation

- Local development: `./scripts/setup-signing.sh` creates a self-signed
  identity so Keychain “Always Allow” grants survive rebuilds. Both build
  scripts use it by default when it exists; an ad-hoc signature instead pins the
  cdhash, so every rebuild (or release update) asks for the keychain password
  again. Saved credentials live in one keychain item and are unlocked with Touch
  ID once per launch (Settings → Security).
- Distribution: `./scripts/package-release.sh` builds a universal app, signs
  with `TAUGE_SIGN_IDENTITY` when present, notarises with
  `TAUGE_NOTARY_*` credentials, and writes a DMG, ZIP, and
  `SHA256SUMS.txt`. [docs/SIGNING.md](docs/SIGNING.md) walks through issuing
  the Developer ID certificate and configuring the secrets.
- CI: the [release workflow](.github/workflows/release.yml) imports a Developer
  ID certificate from repository secrets and publishes the artifacts on a
  `v*` tag. Without secrets it publishes ad-hoc-signed builds and
  [docs/INSTALL.md](docs/INSTALL.md) explains the one-time Gatekeeper step.
- Maintainers: [docs/RELEASING.md](docs/RELEASING.md) lists the exact secrets
  and the tag/verification checklist.

## Architecture

```
Sources/ShellXKit/
  Model/          models, group inheritance, proxy and jump resolution
  Store/          SQLite (WAL) catalog, known hosts, transfer history, settings
  Security/       Keychain, credential storage, AES-256-GCM export encryption
  SSHConfig/      ~/.ssh/config parser and Host * defaults
  SFTP/           SFTP v3 codec and concurrent client
  SSH/            NIOSSH connections, proxies, jump chains, host-key checks
  Transfer/       chunked transfer engine, resume, conflicts, retries
  FileBrowser/    local file service, path and permission formatting
  Import/         Termius vault reader (XSalsa20-Poly1305) and mapping
  Localization/   en.json; L() runtime lookup and live language switch
Sources/ShellXApp/  SwiftUI views, AppState, workspaces, terminal bridge
Sources/ShellXChecks/ executable self-check suite
Vendor/             SwiftTerm and the patched swift-nio-ssh fork
```

## Localisation

Chinese source strings are the keys; English lives in
[`Sources/ShellXKit/Localization/en.json`](Sources/ShellXKit/Localization/en.json).
Every user-visible string is wrapped in `L("中文")`, and the language setting
takes effect immediately without a restart.
`python3 scripts/check-localization.py` verifies that every source key has an
English entry with matching placeholders. Missing entries fall back to Chinese
rather than showing a key. See
[CONTRIBUTING.md](CONTRIBUTING.md#localisation) before adding strings.

## Known limitations

- **SSH features:** SwiftNIO SSH does not implement `keyboard-interactive`
  authentication or expose negotiated algorithms/RTT. `SSH_AUTH_SOCK` agents
  and HTTPS proxies are not wired up.
- **Legacy servers:** SHA-1 `ssh-rsa`/`ssh-dss` signatures are not offered.
  Very old servers that only support those algorithms cannot be reached, and
  the error is reported as a key-exchange failure instead of a vague EOF.
- **Keys:** encrypted PEM keys are not supported; convert them with
  `ssh-keygen -p` or use the OpenSSH format.
- **Terminal:** the byte stream is rendered as UTF-8; the encoding setting only
  affects text opened from SFTP. iTerm2 colour schemes cannot be imported.
- **Workspaces:** panes are arranged as a derived grid plus manual splits, not
  an arbitrary nested tree. Scrollback is not preserved across restarts.
- **SFTP:** large directories load as a single list without virtualisation or
  keyboard navigation; dragging a directory out to Finder is not supported
  (use the transfer centre or a second pane).
- **Termius import:** the local Termius database stores group names but not
  the group hierarchy, so imported hosts land in one group.

See [docs/PRD-COVERAGE.zh-CN.md](docs/PRD-COVERAGE.zh-CN.md) for the detailed
status against the product requirements (in Chinese).

## Privacy

Tauge does not include analytics, crash reporting, or update checks. Network
traffic goes only to the SSH servers and proxies you configure. Termius import
reads the local vault; nothing is uploaded. Session logs are off by default and
stored under `~/Logs`.

Data locations:

- Database: `~/Library/Application Support/ShellX/shellx.sqlite`
- Imported keys: `~/Library/Application Support/ShellX/Keys`
- Logs: `~/Logs/<host>/<date>.log`
- Credentials: macOS Keychain (service `shellx`)

`SHELLX_CATALOG_PATH` (or the `ShellXCatalogPath` default) overrides the
database location; Settings → Advanced can migrate it.

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md)
and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) first, and report vulnerabilities
privately per [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 surgingDandelion.

Built on the work of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
[SwiftNIO SSH](https://github.com/apple/swift-nio-ssh), SwiftNIO,
[swift-crypto](https://github.com/apple/swift-crypto), and
[swift-log](https://github.com/apple/swift-log). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
