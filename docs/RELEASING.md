# Releasing

Releases are built, signed, and notarized **locally** by a maintainer, then uploaded
to GitHub Releases. There is no CI release pipeline — the CI workflow only checks
that the project builds.

## What a release machine needs (one-time)

1. **Developer ID Application certificate** in the login keychain
   (`security find-identity -v -p codesigning` should list it). Created by the
   team's Account Holder at developer.apple.com → Certificates → Developer ID
   Application. Keep the private key backed up — losing it means issuing a new
   certificate.
2. **Notarization credentials** — an App Store Connect API key with access to the
   team, stored once as a keychain profile:

   ```bash
   xcrun notarytool store-credentials yourturn \
     --key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
     --key-id XXXX --issuer <issuer-id>
   ```

3. **`gh` CLI** authenticated against the repository (`gh auth status`).

## Cutting a release

```bash
SIGN_IDENTITY="Developer ID Application: <Your Name> (TEAMID)" \
NOTARY_PROFILE=yourturn ./Scripts/release.sh <version>
```

The script builds a release bundle, signs it with the hardened runtime, submits it
for notarization (waits for Apple), staples the ticket, and re-verifies with
Gatekeeper. The distributable lands at `dist/YourTurn-<version>.zip`.

It works from an isolated staging copy in `dist/` and retries stapling — see the
comments in [`Scripts/release.sh`](../Scripts/release.sh) for the two real-world
failure modes behind that.

Then publish:

```bash
git tag v<version> && git push origin v<version>
gh release create v<version> dist/YourTurn-<version>.zip \
  --title "Your Turn <version>" --generate-notes
```

## Sanity check before uploading

```bash
xcrun stapler validate dist/release-<version>/YourTurn.app
spctl -a -vv dist/release-<version>/YourTurn.app   # → "Notarized Developer ID"
```
