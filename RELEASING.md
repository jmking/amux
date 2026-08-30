# Releasing amux

## The short version

```bash
# 1. bump the version in macos/dist/Amux.app/Contents/Info.plist
#    (CFBundleShortVersionString = marketing version, CFBundleVersion = build number)

# 2. build the artifacts
macos/tools/release.sh

# 3. tag the exact commit the build came from
git tag -a v0.5.0 -m "amux 0.5.0"
git push origin main --tags

# 4. publish, attaching the zip
gh release create v0.5.0 macos/dist/amux-0.5.0-macos.zip \
  --title "amux 0.5.0" --notes-file NOTES.md
```

If `gh` isn't authenticated, run `gh auth login` once, or use the web UI at
`https://github.com/jmking/amux/releases/new?tag=v0.5.0` and drag the zip in.

## How this works, and why

**Tags are the unit of release.** A GitHub release is a tag plus notes plus
attached files. Tag the commit you actually built from, if you tag afterwards
and keep committing, the release points at code that isn't what people
downloaded. `git log --oneline -1` before tagging is a cheap sanity check.

**Semantic-ish versioning.** `MAJOR.MINOR.PATCH`. For an app like this: patch
for fixes, minor for features, major when you break someone's setup (e.g. a
state-file format change that loses layouts). Tags are conventionally prefixed
`v`; the app's `CFBundleShortVersionString` should match so users can report
versions that mean something.

**Two version fields.** macOS wants `CFBundleShortVersionString` (what users
see, `0.4.0`) and `CFBundleVersion` (a monotonically increasing build number).
Sparkle and the App Store both compare the latter, so it must never go
backwards.

**Attach a real installer, not a bare binary.** The DMG with a symlink to
`/Applications` is the Mac convention: mount, drag, done. Zipping the DMG is a
GitHub-ism, browsers and the API handle `.zip` cleanly, and it keeps one
predictable asset name per platform.

**Release notes are for humans.** Lead with what changed and what it means for
the person downloading, not commit subjects. Always include install steps and
the OS/arch requirement.

## Signing and notarization

`macos/tools/release.sh` signs with the `Developer ID Application` cert in the
keychain (hardened runtime, secure timestamp), then notarizes and staples the
DMG automatically, no separate steps needed at release time.

One-time setup, done once per machine:

1. **Developer ID Application** certificate in the keychain (Xcode → Settings
   → Accounts → Manage Certificates → `+` → Developer ID Application).
2. Store notarization credentials (an app-specific password from
   [appleid.apple.com](https://appleid.apple.com), not your main password):
   `xcrun notarytool store-credentials amux-notary --apple-id … --team-id … --password …`
3. If the cert's team ID ever changes, update `SIGN_IDENTITY` at the top of
   `macos/tools/release.sh` (or export it before running the script).

If either is missing, the script falls back to ad-hoc signing and prints a
warning instead of failing, useful for local test builds, but Gatekeeper
blocks that build on anyone else's Mac ("damaged and can't be opened"), so
don't ship one.

## Automating it later

The usual next step is a GitHub Actions workflow on `macos-latest` triggered by
`push: tags: ['v*']` that runs `swift build -c release`, builds the DMG, and
calls `softprops/action-gh-release` to publish. Signing certificates go in
repository secrets as a base64-encoded `.p12` plus its password, imported into a
temporary keychain during the run. Worth it once releases are frequent enough
that doing it by hand gets tedious.

## Also worth knowing

- **Pre-releases**: tick "pre-release" (or `--prerelease`) for betas so they
  don't show as *Latest* and auto-updaters skip them.
- **Draft first**: `gh release create --draft` lets you check the rendering and
  assets, then publish when happy.
- **Checksums**: GitHub shows a SHA-256 per asset. Compare it against
  `shasum -a 256 <file>` locally to confirm the upload wasn't corrupted.
- **In-app updates**: [Sparkle](https://sparkle-project.org) is the standard for
  non-App-Store Mac apps. It reads an appcast XML you publish alongside releases,
  and requires signed, notarized builds.
