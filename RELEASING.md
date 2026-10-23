# Releasing TypeWiser

`./Scripts/release.sh <version>` turns a clean checkout into a notarized,
auto-updating DMG. It needs three things in your keychain first. Each is
set up once, and the script checks all three before it starts building.

## One-time setup

### 1. Developer ID Application certificate

Needs a paid Apple Developer Program membership.

1. Xcode → Settings → Accounts → select your team → **Manage Certificates…**
2. **+** → **Developer ID Application**.

Check it landed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

An "Apple Development" certificate is not the same thing: Gatekeeper rejects
apps signed with it when they're downloaded.

### 2. Notarization credentials

Create an app-specific password at <https://account.apple.com> → Sign-In and
Security → App-Specific Passwords, then store it under the profile name the
script expects:

```bash
xcrun notarytool store-credentials typewiser \
    --apple-id you@example.com --team-id YOURTEAMID
# paste the app-specific password when prompted
```

Your team ID is the 10 characters in parentheses at the end of the certificate
name from step 1. To use a different profile name, set `NOTARY_PROFILE`.

### 3. Sparkle update-signing key

Every update is signed with an EdDSA key, and installed copies only accept
updates signed with it.

```bash
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

This stores the private key in your login keychain and prints the public key.
`release.sh` reads the public key back out with `generate_keys -p` and writes it
into the app. **Back the private key up** (`generate_keys -x sparkle-key.txt`,
then store that file somewhere safe and delete it from disk). If you lose it,
every existing install loses auto-update and has to be re-downloaded by hand.

## Each release

```bash
git switch main && git pull
./Scripts/release.sh 0.2.0
```

The script:

1. Builds a universal (Apple silicon + Intel) app.
2. Sets the version, build number (commit count) and Sparkle feed in Info.plist.
3. Signs Sparkle's helpers, the framework, then the app, all with the hardened
   runtime. The microphone entitlement is in `Resources/TypeWiser.entitlements`.
4. Notarizes and staples the app, wraps it in a DMG, then notarizes and staples
   the DMG.
5. Runs a Gatekeeper check (`spctl`) on both.
6. Writes `build/release/appcast.xml`.

It doesn't publish anything. At the end it prints the `git tag` and
`gh release create` commands. Running them makes the release public and offers
the update to everyone on an older version.

### How the links fit together

- The landing page downloads
  `github.com/fabianferno/typewiser/releases/latest/download/TypeWiser.dmg`.
- Installed apps poll `releases/latest/download/appcast.xml`.

GitHub redirects `latest` to the newest non-prerelease release, so every
release must attach both `TypeWiser.dmg` and `appcast.xml`. Mark a release
as a prerelease to keep it off both links.

### Before the first public release

Run the rows in `docs/manual-qa.md` on the notarized build, on a Mac (or a
fresh user account) that has never run TypeWiser. A dev build from
`bundle-app.sh` inherits your existing permission grants, so it can't show you
what a stranger sees.
