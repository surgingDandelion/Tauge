# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
