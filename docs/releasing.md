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
   - writes `build/release/Quoth-0.4.0.dmg` and its `.sha256`.
3. Test the DMG as a new user would, ideally in a separate macOS user account:
   - open the DMG and drag Quoth to Applications;
   - launch it and confirm the Gatekeeper block appears;
   - use **Open Anyway**, download models on the Setup page, grant permissions, and dictate.
4. Publish (the commands are printed at the end of `release.sh`):
   ```bash
   git tag v0.4.0 && git push origin v0.4.0
   gh release create v0.4.0 build/release/Quoth-0.4.0.dmg build/release/Quoth-0.4.0.dmg.sha256 \
     --title "Quoth 0.4.0" --notes-file docs/release-notes.md
   ```

Version numbers follow `X.Y.Z`. The build number is the commit count, so it always increases.
