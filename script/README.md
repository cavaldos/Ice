# Scripts

Local dev and release helpers. Run from the repository root.

## Local development

```bash
# Build Debug and launch the app
./script/run.sh

# Build Release DMG into release/ (optional version override for About)
./script/build.sh [vX.Y.Z]

# Same lint + build as CI — run before pushing (optional tag check)
./script/ci-local.sh [vX.Y.Z]
```

Install SwiftLint first if needed: `brew install swiftlint`.

## Every release (2 commands)

Automated releases so users get Sparkle update notifications — no manual version edits.

```bash
# 1. Commit your code, then create + push the tag (lints/builds first, version comes from the tag name)
./script/release.sh vX.Y.Z

# 2. Wait for CI to go green, then publish the appcast (this is what makes users see the update)
./script/update-appcast.sh vX.Y.Z
```

After step 2, open `https://cavaldos.github.io/ice-releases/appcast.xml` — if the new tag is listed, you're done.

## Tag rules

* Format `vX.Y.Z` (e.g. `v0.11.14`) and **greater** than the version users have — Sparkle ignores older builds.
* Never re-tag an old number. No need to touch the version in Xcode — CI injects `MARKETING_VERSION` from the tag name.
* `release.sh` refuses a dirty tree — commit + push first.

## What `update-appcast.sh` needs

* `gh` logged in (`gh auth login`) and the `generate_appcast` tool (from the Sparkle 2.x dist).
* The private key matching `SUPublicEDKey` in `Ice/Info.plist`: uses the Keychain key by default;
  pass `--key ~/.sparkle/sparkle-priv.pem` (or export `SPARKLE_PRIVATE_KEY`) if the key lives in a file.
* First run only: the `cavaldos/ice-releases` repo must exist with GitHub Pages enabled (already done).

## No update showing? Check

1. Is the new tag in `appcast.xml` (link above)?
2. Does the user's app have **Automatically check for updates** on (default for fresh installs: on)?
3. Was the installed app signed with the same key — builds signed with the old upstream key need one manual download.
