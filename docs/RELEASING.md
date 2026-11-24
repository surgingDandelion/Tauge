# Releasing Tauge

Releases are cut by [`scripts/release.sh`](../scripts/release.sh) and built by
[`.github/workflows/release.yml`](../.github/workflows/release.yml). The tag is
the release trigger. Pushing `vX.Y.Z` builds Tauge for Apple silicon (`arm64`),
optionally signs and notarises it, then publishes the DMG, ZIP, and checksums.

## 1. Cut a release

Start from a clean `main` that exactly matches `origin/main`:

```bash
git switch main
git pull --ff-only
./scripts/release.sh patch
```

Use `minor` or `major` for a larger bump, or name the version explicitly:

```bash
./scripts/release.sh 1.2.0 --notes-file /tmp/notes.md
```

When the version has no `CHANGELOG.md` section yet, pass the markdown body with
`--notes` or `--notes-file`; the script inserts it under `## [Unreleased]`.
If the section already exists, omit the notes flags and the script uses it.

The script will:

1. Refuse a dirty tree, a branch other than `main`, a `HEAD` that is not
   `origin/main`, an existing tag, or a version that does not increase.
2. Run `scripts/check-localization.py` and `swift run --disable-sandbox
   TaugeChecks` (skip with `--skip-checks`; CI still runs both).
3. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Resources/Info.plist`.
4. Add the `CHANGELOG.md` section when needed.
5. Commit `chore(release): vX.Y.Z`, push `main`, create an annotated tag, and
   push it.
6. Wait for the published release, preferring the GitHub API and falling
   back to the public release page, then verify the DMG, ZIP, and
   `SHA256SUMS.txt` (including GitHub's recorded SHA-256 digests when the API
   is available).

Useful options:

| Option | Purpose |
| --- | --- |
| `--dry-run` | Print the plan and exit without changing files or pushing |
| `--yes` | Skip the confirmation prompt (required in non-interactive shells) |
| `--current` | Tag the version already in `Info.plist`, without a bump |
| `--no-wait` | Push the tag and exit instead of waiting for GitHub |
| `--skip-checks` | Skip the local checks; let CI be the gate |
| `--repo OWNER/REPO` | Override the repository inferred from `origin` |

`--current` is for recovering after a tag push was interrupted, not for
re-releasing a version that is already published. It still refuses an existing
tag and still requires a clean tree.

The release workflow extracts the matching `CHANGELOG.md` section and uses it
as the "What's changed" text on the GitHub Release, so write notes for users
rather than for maintainers.

## 2. Repository secrets

Signing and notarisation are optional. Without them the workflow still
publishes an ad-hoc-signed build, which macOS blocks on first launch until the
user allows it (see [`docs/INSTALL.md`](INSTALL.md)).

To publish a build that installs without a Gatekeeper prompt, follow
[`docs/SIGNING.md`](SIGNING.md) to issue the Developer ID certificate and add
these **Actions secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | Password used when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any temporary password for the CI keychain |
| `APPLE_ID` | Apple ID enrolled in the Developer Program |
| `APPLE_TEAM_ID` | Ten-character team identifier |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarytool |

Export the certificate from Keychain Access: select **Developer ID Application:
… (TEAMID)** together with its private key, choose *Export Items*, and save a
`.p12` with a password. The workflow imports it into a temporary keychain and
uses it only for that run.

An App Store Connect API key can replace the Apple ID trio; see
[`scripts/package-release.sh`](../scripts/package-release.sh) for the
`TAUGE_NOTARY_KEY_*` variables.

## 3. Verify

The script verifies the published metadata. For a byte-level check, download the
assets and run:

```bash
shasum -a 256 -c SHA256SUMS.txt
spctl --assess --type execute --verbose=2 /Applications/Tauge.app
xcrun stapler validate /Applications/Tauge.app
```

On a notarised build, `spctl` prints `source=Notarized Developer ID` and
`stapler` reports a valid ticket. On an ad-hoc build, `spctl` rejects the app:
that is expected and documented for users.

## 4. Release assets and the updater

The updater consumes the release directly. These rules apply to arm64 releases:

- The release must be **published, stable, and not a draft or pre-release**.
  The updater asks GitHub for `/releases/latest`, which ignores drafts and
  pre-releases, and it refuses to install either.
- The tag must be `vX.Y.Z` and must exactly match `CFBundleShortVersionString`.
  The workflow already enforces the match, and the updater compares the tag's
  semantic version with the running bundle.
- Publish `Tauge-<version>.dmg` for manual installation and
  `Tauge-<version>.zip` for in-app updates. `SHA256SUMS.txt` must list both files.
- Every asset URL must be HTTPS. The updater rejects anything else.
- Release notes become the "What's New" text in the update window. The workflow
  now fills them from the matching `CHANGELOG.md` section.

For v1.2.9 only, the workflow adds `Tauge-1.2.9-arm64.zip` so v1.2.8 clients
can update. It copies `Tauge-1.2.9.zip` byte for byte and lists both filenames
with the same SHA-256 digest in `SHA256SUMS.txt`.

Verify the updater from an Apple silicon Mac running an earlier version. For
v1.2.9, exercise the canonical ZIP from v1.2.7 and the alias from v1.2.8:

```bash
/Applications/Tauge.app/Contents/MacOS/Tauge --check-updates
```

It should print `update available: <new> (current <old>)` and the ZIP URL, then
exit 0. Then use **Tauge → Check for Updates…** to walk through download,
checksum verification, in-place replacement, and relaunch.

## 5. If the workflow fails

The tag is the trigger, so a failure before "Publish GitHub Release" leaves no
release behind. Fix the problem, delete the tag locally and remotely, and re-run
the script with `--current`:

```bash
git push origin :refs/tags/vX.Y.Z
git tag -d vX.Y.Z
./scripts/release.sh --current --yes
```

If the release was already published, cut a new patch version instead. Do not
try to make an existing version point at different assets: in-app updates treat
the version as immutable once users have downloaded it.
