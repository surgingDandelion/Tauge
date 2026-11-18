# Security policy

## Supported versions

| Version | Supported |
| ------- | --------- |
| 1.x     | Yes       |

## Reporting a vulnerability

Please do **not** open a public issue for security problems. Report them
privately through GitHub's [private vulnerability reporting](https://github.com/surgingDandelion/Tauge/security/advisories/new)
so a fix can be prepared before disclosure.

Include:

- the affected version and macOS version
- a description of the issue and its impact
- reproduction steps or a proof of concept
- any suggested mitigation

You can expect an acknowledgement within a few days. Once a fix is available,
a GitHub Security Advisory and a patched release will be published, and
reporters will be credited unless they prefer otherwise.

## Scope

Tauge stores credentials in the macOS Keychain, verifies host keys on first
use, and talks directly to SSH servers. The following are in scope:

- credential or private-key disclosure (Keychain, SQLite database, logs)
- host-key verification bypasses
- command or path injection in importers, SFTP operations, or `~/.ssh/config`
  parsing
- memory-safety issues in the vendored SSH/Terminal code
- privilege escalation through the updater or helper scripts

Issues in third-party dependencies should also be reported upstream. The
vendored `swift-nio-ssh` fork and `SwiftTerm` are tracked in this repository;
please report problems there as well so the patch can be carried forward.
