# Releasing

How to cut a new release DMG. Users download from [Releases](https://github.com/RyanBeasley1994/Grok-macOS/releases).

Use **your** Apple Developer team. Do not reuse the original project's team ID, bundle identifier, or notarization profile.

## One-time setup

1. In Xcode, set **Signing & Capabilities** to your development team. Change `PRODUCT_BUNDLE_IDENTIFIER` if you are shipping your own signed build (the upstream ID is `com.nhershy.Grok-macOS`).
2. Create an **app-specific password** at [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords.
3. Store notarization credentials, using your Team ID from [developer.apple.com/account](https://developer.apple.com/account):

```sh
xcrun notarytool store-credentials "grok-notary" --apple-id <your-apple-id> --team-id <YOUR_TEAM_ID>
```

Paste the app-specific password when prompted. The release script looks up the profile named `grok-notary`.

## Cutting a release

1. Bump **MARKETING_VERSION** (and **CURRENT_PROJECT_VERSION**) in Xcode: target *Grok-macOS* → Build Settings → Versioning.
2. Run the release script from the repo root, with your Team ID:

   ```sh
   DEVELOPMENT_TEAM=<YOUR_TEAM_ID> ./scripts/release.sh
   ```

   It archives a Release build, signs it with your Developer ID certificate, notarizes the app and the DMG with Apple (two waits of ~1–5 minutes each), staples the tickets, and verifies everything with `stapler validate` and `spctl`. Output lands at `dist/Grok-<version>.dmg`.

3. Publish it:

   ```sh
   gh release create v<version> dist/Grok-<version>.dmg --title "Grok <version>" --notes "What changed"
   ```

## Notes

- The first `xcodebuild ... -allowProvisioningUpdates` run may prompt for keychain access to the signing key — click **Always Allow**.
- If notarization is rejected, the script prints the `xcrun notarytool log <id>` command that shows Apple's reasons.
- If the credential check fails (for example the app-specific password was revoked), redo the one-time setup above.
