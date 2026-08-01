# Yapboard Release Setup & Process

This document covers the one-time setup required for Sparkle auto-updates and the process for cutting a release.

## No Notarization (Ad-Hoc Signing Only)

Yapboard is distributed **without** an Apple Developer Program membership ($99/year cost ruled out), so there is no notarization and no Developer ID certificate. The app is signed ad-hoc only (`codesign --force --deep -s -`), which means every user will see a macOS Gatekeeper block on first launch.

### Gatekeeper Block Workarounds

Users have two standard options to open the app on first launch:

**Option 1: System Settings (macOS 15+)**
1. Launch the app normally — you'll see a Gatekeeper block
2. Go to **System Settings > Privacy & Security**
3. Scroll down to find the blocked-app notice and click **Open Anyway**
4. Confirm in the follow-up dialog
5. Launch the app again, and it will now run normally

**Option 2: xattr Command**
1. Open Terminal
2. Run: `xattr -d com.apple.quarantine /Applications/Yapboard.app`
3. Then open the app normally

**Note on Gatekeeper and Updates**: The Gatekeeper check only happens on the very first launch for a given signature — this holds for manually-downloaded zips and user installs. However, after Sparkle updates the app in place, the signature changes and TCC (microphone permission) may need re-granting; see below.

After this one-time step, the app works normally and Sparkle auto-updates proceed without friction.

### TCC Permission Re-Grant After Updates

Because Yapboard is ad-hoc signed (no stable Team ID), each build has a different code signature identity. When Sparkle installs an update, macOS TCC (Transparency, Consent, and Control) may treat the updated binary as a "different app" — users might see a re-prompt to grant microphone permission, or the permission grant could go stale. This is expected behavior given the no-notarization tradeoff, not a bug. Users who see this after an update can simply re-grant microphone permission in **System Settings > Privacy & Security > Microphone**.

## One-Time Sparkle Key Setup

Before cutting the first release, generate an EdDSA keypair for Sparkle to use when signing updates:

1. **Build first** (or ensure `.build/` already has Sparkle resolved):
   ```bash
   swift build
   ```

2. **Find and run generate_keys**:
   ```bash
   find .build -name "generate_keys" -type f
   ```
   This will be at something like `.build/artifacts/sparkle/Sparkle/bin/generate_keys` or `.build/checkouts/sparkle-macos-.../Sparkle/bin/generate_keys`.

   Run it:
   ```bash
   /path/to/generate_keys
   ```

3. **Copy the public key** from the tool's output into `SUPublicEDKey` in `Sources/Yapboard/Resources/Info.plist`:
   ```xml
   <key>SUPublicEDKey</key>
   <string>PASTE_PUBLIC_KEY_HERE</string>
   ```

4. **Commit this change**:
   ```bash
   git add Sources/Yapboard/Resources/Info.plist
   git commit -m "Add Sparkle public key"
   ```

5. **Critical**: Never generate a second keypair. The public key is already shipped to installed users; a new private key would invalidate the ability to sign future updates.

6. **Backup the private key immediately**: Export the Sparkle private key from your local Keychain and store it securely offline (e.g., in a password manager or encrypted backup). Losing this key permanently breaks auto-updates for every already-installed user — there is no way to regenerate a key that matches the already-shipped public key.

The private key is stored in your local Keychain under the label Sparkle will prompt for during `generate_keys` (typically something like `com.kirpal.yapboard` or the app's bundle ID). `scripts/release.sh` will use this key to sign updates automatically.

## Cutting a Release

Once one-time setup is complete, releasing a new version is straightforward:

1. **Bump the version** manually in `Sources/Yapboard/Resources/Info.plist`:
   - Update `CFBundleShortVersionString` to the new semantic version (e.g., `1.1.1`)
   - **Do not** manually modify `CFBundleVersion` — `scripts/release.sh` auto-increments it
   - Commit this change:
     ```bash
     git add Sources/Yapboard/Resources/Info.plist
     git commit -m "Bump version to 1.1.1"
     ```
   
   **Important for Sparkle**: Sparkle compares `sparkle:version` (which is sourced from `CFBundleVersion`, the internal build counter) to decide if an update is newer than the installed version. The `scripts/release.sh` script automatically increments `CFBundleVersion` during the release process, so you only need to manually bump `CFBundleShortVersionString` for new semantic versions. The visible version numbers (like "1.1.1") go in `CFBundleShortVersionString`; the Sparkle comparison logic uses the auto-incrementing `CFBundleVersion`.

2. **Run the release script**:
   ```bash
   ./scripts/release.sh
   ```
   This will:
   - Build the app in release mode
   - Assemble and ad-hoc sign the .app bundle
   - Zip it as `Yapboard-<version>.zip`
   - Generate a Sparkle-signed appcast (`appcast.xml`)
   - Publish both to GitHub Releases at `https://github.com/kirpalricky/yapboard/releases`

3. **Verify the release**:
   - Check GitHub: https://github.com/kirpalricky/yapboard/releases/tag/v1.1.1 (adjust version)
   - Ensure both `Yapboard-1.1.1.zip` and `appcast.xml` are present
   - The appcast URL should be available at: https://github.com/kirpalricky/yapboard/releases/latest/download/appcast.xml

## Publishing to Homebrew

After a release is published to GitHub Releases:

1. **Get the sha256 of the zip**:
   ```bash
   shasum -a 256 release/Yapboard-1.1.1.zip
   ```

2. **Update the Homebrew cask formula** (in the separate tap repo `homebrew-yapboard`):
   - Update the `version` field
   - Replace `sha256 :no_check` with the actual sha256
   - Commit and push

3. **Users can then install/update via**:
   ```bash
   brew install kirpalricky/yapboard/yapboard
   # or
   brew upgrade yapboard
   ```

## Troubleshooting

**"Sparkle tools (generate_appcast, sign_update) not found in .build/"**
- Run `swift build` to ensure Sparkle is resolved
- Then try `scripts/release.sh` again

**"SUPublicEDKey is not set in Info.plist"**
- Follow the one-time setup step above to generate and insert the public key
- Ensure you committed the change

**"generate_appcast failed"**
- Check that the `release/` directory contains a valid `.zip` file
- Ensure the Sparkle tools are up to date (rebuild: `swift build`)
- Check system logs: `log show --level=debug` may have Sparkle details

**Gatekeeper blocks the released .app on first launch**
- This is expected and normal (no notarization). Instruct users to:
  - Right-click Open, or
  - Run `xattr -d com.apple.quarantine /Applications/Yapboard.app`
- Auto-updates work normally after that one-time step.
