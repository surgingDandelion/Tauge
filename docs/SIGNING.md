# Signing and notarising Tauge

Tauge ships as a macOS app outside the App Store. For a download that opens
without a Gatekeeper warning, the app must be signed with a **Developer ID
Application** certificate and notarised by Apple. Both require a paid
[Apple Developer Program](https://developer.apple.com/programs/) membership;
there is no free certificate that Gatekeeper trusts for distribution.

This repository contains the complete signing and notarisation pipeline. It
does **not** contain a certificate or private key. The maintainer supplies
them through GitHub Actions secrets (or environment variables for a local
build).

## 1. Create the certificate

1. In **Keychain Access**, choose **Certificate Assistant → Request a
   Certificate From a Certificate Authority**.
2. Enter the Apple ID e-mail, a common name such as Tauge Developer ID, and
   choose **Saved to disk**. Save CertificateSigningRequest.certSigningRequest.
3. In the [Apple Developer portal](https://developer.apple.com/account/resources/certificates/list),
   choose **Certificates → + → Developer ID → Developer ID Application**.
4. Upload the CSR, download the .cer, and double-click it to install it in
   the login keychain.
5. Confirm the identity is present:

    security find-identity -v -p codesigning
    # "Developer ID Application: Your Name (TEAMID)"

Keep the private key in the login keychain. Never commit it.

## 2. Export a .p12 for CI

1. In Keychain Access, select the **Developer ID Application** certificate and
   expand it to include its private key.
2. Right-click → **Export Items…**, choose .p12, and set a password.
3. Base64-encode it for the repository secret:

    base64 -i DeveloperID.p12 | pbcopy

## 3. Notarisation credentials

Create an **app-specific password** for the Apple ID at
[appleid.apple.com](https://appleid.apple.com) (Sign-In and Security →
App-Specific Passwords). The team ID is shown in the Developer portal under
**Membership details**.

Alternatively create an App Store Connect API key (Users and Access → Keys)
and use TAUGE_NOTARY_KEY_PATH, TAUGE_NOTARY_KEY_ID, and
TAUGE_NOTARY_KEY_ISSUER locally.

## 4. Configure GitHub Actions

Add these **repository secrets** under **Settings → Secrets and variables →
Actions**:

| Secret | Value |
| --- | --- |
| MACOS_CERT_P12_BASE64 | Base64 of the exported .p12 |
| MACOS_CERT_PASSWORD | Password chosen when exporting the .p12 |
| KEYCHAIN_PASSWORD | Any temporary password for the CI keychain |
| APPLE_ID | Apple ID enrolled in the Developer Program |
| APPLE_TEAM_ID | Ten-character team identifier |
| APPLE_APP_SPECIFIC_PASSWORD | App-specific password for notarytool |

The [release workflow](../.github/workflows/release.yml) imports the
certificate into a temporary keychain, signs with the hardened runtime,
notarises the app, staples the ticket, signs the DMG, and publishes the
release.

## 5. Build and verify locally

    export TAUGE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
    export TAUGE_SIGN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    export TAUGE_NOTARY_APPLE_ID="you@example.com"
    export TAUGE_NOTARY_TEAM_ID="TEAMID"
    export TAUGE_NOTARY_PASSWORD="app-specific-password"

    ./scripts/package-release.sh

    spctl --assess --type execute --verbose=2 dist/Tauge.app
    # accepted, source=Notarized Developer ID
    xcrun stapler validate dist/Tauge.app
    xcrun stapler validate dist/release/Tauge-1.0.0.dmg

package-release.sh refuses to start if TAUGE_SIGN_IDENTITY names a
Developer ID identity that is not installed, so a typo cannot silently produce
an unsigned release.

## Without a certificate

If no Developer ID identity is supplied, the release script produces an
**ad-hoc signed** build. It is functional, but macOS quarantines downloads and
shows “cannot be opened because the developer cannot be verified”. Users can
approve it once in **System Settings → Privacy & Security → Open Anyway**, or
remove the quarantine attribute from a build whose checksum they verified:

    xattr -dr com.apple.quarantine /Applications/Tauge.app

This is documented for users in [INSTALL.md](INSTALL.md). It is not equivalent
to notarisation: every new download triggers the prompt again.
