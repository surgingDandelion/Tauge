# Contributing to Tauge

Thanks for taking the time to contribute. Tauge is a native macOS app built
with SwiftPM only — no Xcode project, no external package manager.

## Requirements

- macOS 13 or later (Apple silicon or Intel)
- Command Line Tools with Swift 5.9 or later (`xcode-select --install`)
- Python 3 (only for regenerating icons)

## Get started

```bash
git clone https://github.com/surgingDandelion/Tauge.git
cd Tauge

export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/modulecache"

swift build --disable-sandbox
swift run --disable-sandbox ShellXChecks
```

`--disable-sandbox` is only needed in environments where `sandbox-exec` is
restricted (for example, when building inside another sandbox). A normal
Terminal session does not need it.

To produce a runnable app bundle:

```bash
./scripts/build-app.sh release   # -> dist/Tauge.app
open dist/Tauge.app
```

For a stable local code signature (so Keychain "Always Allow" grants survive
rebuilds), run `./scripts/setup-signing.sh` once. It creates a self-signed
certificate in a dedicated Keychain. Never commit signing material.

## Making changes

1. Open an issue before starting significant work so the design can be
   discussed.
2. Keep the change focused; unrelated refactors belong in a separate PR.
3. Add or update checks in `Sources/ShellXChecks` for anything testable
   without a live server. The suite is a plain executable because the Command
   Line Tools SDK does not ship XCTest.
4. Run the self-check suite and `./scripts/build-app.sh release` before
   opening a pull request.
5. Describe the motivation, the approach, and how you tested it.

### Code style

- Swift 5.9-compatible source, 4-space indentation, 100-column soft limit.
- The UI layer uses `Sources/ShellXApp/ViewState.swift` instead of SwiftUI
  macros because the Command Line Tools toolchain does not ship
  `libSwiftUIMacros.dylib`. Do not introduce `@State`, `@StateObject`,
  `@ObservedObject`, `@EnvironmentObject`, or `@Published` in new code; use the
  wrappers in that file.
- Do not modify `Vendor/` unless the change is a documented patch to the
  vendored fork. Explain vendored changes in the pull request.

### Releases

See [docs/RELEASING.md](docs/RELEASING.md) for the version bump, tag, secrets,
and verification checklist. Do not tag a release while CI is red.

### Localisation

Every user-visible string in `Sources/ShellXApp` and `Sources/ShellXKit` must
be wrapped with `L(...)`:

```swift
Text(L("新建主机"))
alert.messageText = L("删除「%@」？", host.name)
```

Chinese source strings are the keys; English translations live in
`Sources/ShellXKit/Localization/en.json`. When adding or changing a key:

1. Wrap the string with `L` (and `import ShellXKit` in the app target if it is
   not already imported).
2. Add the English value to `en.json`. Keep `%@`, `%d`, `%s`, and `%%`
   placeholders in the same order.
3. Do not translate data values that are persisted or compared (for example
   the `收藏` filter tag or `case "工作区"` discriminators). If a value is both
   displayed and stored, keep the stored value stable and translate only the
   presentation.
4. Run `python3 scripts/check-localization.py`. It fails when a source key is
   missing from `en.json` or when placeholder counts differ; CI runs it too.

### Commit messages

Use short imperative subjects, for example:

```
add SOCKS5h proxy support
fix focus handoff after closing the find bar
docs: document notarisation secrets
```

Reference issues with `Fixes #123` where applicable.

## Reporting bugs

Please include:

- Tauge version (Tauge → About) and macOS version
- Steps to reproduce, expected and actual behaviour
- Relevant lines from the session log or the app's stderr output
- Whether the host uses a jump host or proxy

Security issues must be reported privately — see [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
