# Releasing Tauge

Releases are cut from a tag and built by
[`.github/workflows/release.yml`](../.github/workflows/release.yml).

## 1. Prepare the version

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` (for example
   `1.0.0`). The release workflow refuses a tag that does not match it.
2. Add the matching entry to [`CHANGELOG.md`](../CHANGELOG.md).
3. Run the checks locally:

   ```bash
   python3 scripts/check-localization.py
   swift run --disable-sandbox ShellXChecks
   ```

4. Commit, push `main`, and confirm the CI workflow is green.

## 2. Tag

```bash
git tag -a v1.0.0 -m "Tauge 1.0.0"
git push origin v1.0.0
```

The tag starts the release workflow, which builds a universal app, signs and
notarises it, and publishes `Tauge-<version>.dmg`, `Tauge-<version>.zip`, and
`SHA256SUMS.txt` on the GitHub Release.

## 3. Repository secrets

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

## 4. Verify

```bash
shasum -a 256 -c SHA256SUMS.txt
spctl --assess --type execute --verbose=2 /Applications/Tauge.app
xcrun stapler validate /Applications/Tauge.app
```

On a notarised build, `spctl` prints `source=Notarized Developer ID` and
`stapler` reports a valid ticket. On an ad-hoc build, `spctl` rejects the app:
that is expected and documented for users.

## 5. Release assets and the updater

The updater in 1.1.0 and later consumes the release directly, so the asset
contract is part of the release:

- The release must be **published, stable, and not a draft or pre-release**.
  The updater asks GitHub for `/releases/latest`, which ignores drafts and
  pre-releases, and it refuses to install either.
- The tag must be `vX.Y.Z` and must exactly match `CFBundleShortVersionString`.
  The workflow already enforces the match, and the updater compares the tag's
  semantic version with the running bundle.
- `Tauge-<version>.zip` and `SHA256SUMS.txt` must keep those exact names.
  `SHA256SUMS.txt` must list the ZIP. The DMG is for new installs; the updater
  installs from the ZIP.
- Every asset URL must be HTTPS. The updater rejects anything else.
- Release notes become the "What's New" text in the update window. Write them
  for users rather than leaving the auto-generated changelog link alone.

After publishing, verify from a machine running the previous version:

```bash
/Applications/Tauge.app/Contents/MacOS/Tauge --check-updates
```

It should print `update available: <new> (current <old>)` and the ZIP URL, then
exit 0. Then use **Tauge → Check for Updates…** to walk through download,
checksum verification, in-place replacement, and relaunch.
