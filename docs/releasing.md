# Releasing

Quoth is released as a free download on GitHub Releases, signed with the project's own certificate rather than an Apple Developer ID (see [Distribution](distribution.md)). Releases are built on the maintainer's Mac, so the signing key never leaves it.

## The signing certificate

Every release is signed with the same self-signed certificate, **"Quoth Dev"**:

- SHA-1 `CA876DC71337A6245EBD3D36CB300388BCC88A77`
- Valid until October 2036

macOS remembers a user's permission grants (Accessibility, Input Monitoring, Microphone) for apps signed by this certificate. Signing with any other certificate, even another one named "Quoth Dev", silently breaks those grants for every user on update. `scripts/release.sh` refuses to build with any other certificate.

**Back it up** (once, and keep it safe; without it, no future update can keep users' permissions):

1. Open **Keychain Access**, choose the **login** keychain, then **My Certificates**.
2. Right-click **Quoth Dev** → **Export "Quoth Dev"…**, save as `Quoth Dev.p12`, and set a strong password.
3. Store the file and its password somewhere that isn't this Mac, such as a password manager. Never commit it.

To restore on another Mac, double-click the `.p12` and enter its password. Then run `security find-certificate -c "Quoth Dev" -Z` and check the SHA-1 above. Before 2036, plan a migration (a new certificate means users re-grant permissions once).

## The update key (Sparkle)

Installed copies of Quoth update themselves with [Sparkle](https://sparkle-project.org). Each release's DMG is signed with a second, separate secret: an EdDSA **update key**. Every installed Quoth carries the matching public key (`SUPublicEDKey` in `Info.plist`) and refuses any update not signed with it. Sparkle also refuses an update whose app isn't signed with the same "Quoth Dev" certificate.

**Create it** (once, before the first release):

```bash
scripts/sparkle-tools.sh                                # fetches Sparkle's tools (pinned, checksum-verified)
build/sparkle/bin/generate_keys --account app.quoth     # creates the key in your login keychain
```

It prints a public key. Put it in `Sources/Quoth/Resources/Info.plist` as the `SUPublicEDKey` value and commit. The public key isn't secret. `release.sh` refuses to build while it's empty, and checks that the DMG's signature matches it.

**Back it up** (once):

```bash
build/sparkle/bin/generate_keys --account app.quoth -x ~/Desktop/quoth-update-key.txt
```

Store that file with the certificate backup (password manager, not this Mac), then delete it from the Desktop. If it's lost, existing users can't receive updates and must download the next version by hand.

The first `release.sh` run may ask whether `sign_update` may use the key: choose **Always Allow**.

## Making a release

1. Update `docs/release-notes.md` ("What's new"; keep the install steps).
2. Commit everything, then build:
   ```bash
   scripts/release.sh 0.4.0
   ```
   This script:
   - checks the certificate and that nothing is uncommitted;
   - runs the unit tests;
   - builds the engines (pinned) and the app with the version stamped;
   - verifies every signature against the pinned certificate;
   - writes `build/release/Quoth-0.4.0.dmg` and its `.sha256`;
   - signs the DMG with the update key, checks the signature against the app's public key, and writes `build/release/appcast.xml`.
3. Test the DMG as a new user would, ideally in a separate macOS user account:
   - open the DMG and drag Quoth to Applications;
   - launch it and confirm the Gatekeeper block appears;
   - use **Open Anyway**, download models on the Setup page, grant permissions, and dictate.
4. Publish (the commands are printed at the end of `release.sh`):
   ```bash
   git tag v0.4.0 && git push origin v0.4.0
   gh release create v0.4.0 build/release/Quoth-0.4.0.dmg build/release/Quoth.dmg \
     build/release/Quoth-0.4.0.dmg.sha256 build/release/appcast.xml \
     --title "Quoth 0.4.0" --notes-file docs/release-notes.md
   ```

Version numbers follow `X.Y.Z`. The build number is the commit count, so it always increases (Sparkle compares build numbers).

Installed apps read `https://github.com/weareaiforfun-hub/quoth/releases/latest/download/appcast.xml`, which GitHub redirects to the newest release's `appcast.xml`. So every release must include its `appcast.xml` and a copy of the DMG named `Quoth.dmg` (the README's download link), and drafts or pre-releases don't count as "latest".

### Testing an update locally

`release.sh` accepts a throwaway key so updates can be tested without the real one:
- `SPARKLE_PUBLIC_KEY`, `SPARKLE_KEY_FILE`, `QUOTH_BUILD`, `DOWNLOAD_BASE` and `ALLOW_DIRTY` (see the script header).
- With the debug hooks on, the defaults key `debugFeedURL` points the app at another feed.
- `post.swift update` checks and downloads silently, and `post.swift quit` installs.
- The feed must be served over http(s) from a server that is already running.
