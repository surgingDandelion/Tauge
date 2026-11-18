# Third-party notices

Tauge is distributed under the [MIT License](LICENSE). It includes or links
against the following third-party components. Their licenses apply to those
components, and the full texts are reproduced in the linked repositories and in
the vendored directories.

## Vendored source

### SwiftTerm

- Copyright © 2019–2026 Miguel de Icaza and contributors
- License: MIT
- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Location: `Vendor/SwiftTerm`
- License text: `Vendor/SwiftTerm/LICENSE`

SwiftTerm in turn derives from xterm.js, SourceLair, Christopher Jeffrey’s
work, and the Powerline Extra Symbols project; those notices are preserved in
the same file.

### swift-nio-ssh (patched fork)

- Copyright © 2019–2026 Apple Inc. and the SwiftNIO project authors
- License: Apache License 2.0
- Upstream: https://github.com/apple/swift-nio-ssh
- Location: `Vendor/swift-nio-ssh`
- License text: `Vendor/swift-nio-ssh/LICENSE.txt`

This fork carries a local patch that enables RFC 8332 `rsa-sha2-256` and
`rsa-sha2-512` public-key signatures, used when a server requires RSA keys.
The patch is limited to signature negotiation and is documented in the
repository history.

## Swift Package Manager dependencies

These are resolved from their upstream repositories at build time; their
license files are included in each package checkout.

| Component | License | Upstream |
| --------- | ------- | -------- |
| swift-nio | Apache-2.0 | https://github.com/apple/swift-nio |
| swift-crypto | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-log | Apache-2.0 | https://github.com/apple/swift-log |

## Icons

The application icon is original artwork created for this project. The
menu-bar and toolbar glyphs are SF Symbols, used under the
[Apple SF Symbols license](https://developer.apple.com/sf-symbols/).

## Trademarks

macOS, Apple, and SF Symbols are trademarks of Apple Inc. Termius is a
trademark of Termius Corporation. Tauge is not affiliated with, endorsed by, or
sponsored by any of these companies.
