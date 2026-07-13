# Releasing Tusk

Producing a build that a stranger can download from a website and open without
macOS calling it damaged. Three things have to be true:

1. **Self-contained** — no dependency on the build machine's Homebrew.
2. **Signed** with a Developer ID certificate, using the hardened runtime.
3. **Notarized** by Apple and **stapled**, so it validates even offline.

`make release` does all three. The rest of this doc is the one-time setup and the
reasoning behind the parts that are easy to get subtly wrong.

---

## One-time setup

### 1. Developer ID Application certificate

Requires a paid Apple Developer Program membership. In **Xcode → Settings →
Accounts**, add your Apple ID, select it, click **Manage Certificates…**, then
**+ → Developer ID Application**. Xcode generates the keypair and installs it in
your login keychain.

Verify:

```sh
security find-identity -v -p codesigning     # must list "Developer ID Application: ..."
```

> If that menu item is greyed out, you are not the Account Holder for the team, or
> the membership isn't active. Developer ID certificates are Account Holder–only.

The Makefile auto-detects the identity. Override it if you have several:

```sh
make release SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

### 2. Notarization credentials

Notarization uploads the build to Apple, which needs an **app-specific password**
(your normal Apple ID password will not work). Create one at
[account.apple.com](https://account.apple.com) → Sign-In and Security →
App-Specific Passwords, then store it in the keychain once:

```sh
xcrun notarytool store-credentials "tusk" \
  --apple-id you@example.com \
  --team-id YOURTEAMID \
  --password xxxx-xxxx-xxxx-xxxx
```

The profile name (`tusk`) is what the Makefile looks for; override with
`NOTARY_PROFILE=...`. The password lives in the keychain, never in the repo.

---

## Cutting a release

```sh
make release          # bundle -> sign -> dmg -> notarize -> staple
```

It prints the DMG path and its sha256. Then:

1. Bump `VERSION` in the `Makefile` (and `version` in `packaging/Casks/tusk.rb`).
2. Tag and push: `git tag v0.1.0 && git push --tags`
3. Create a GitHub Release and attach `dist/Tusk-<version>.dmg`.
4. Point your website's download button at the release asset URL:
   `https://github.com/veshnu/tusk/releases/download/v<version>/Tusk-<version>.dmg`
   — or, better, at `.../releases/latest/download/Tusk.dmg` so the link never
   goes stale (requires a fixed asset name).
5. Update the cask's `sha256` with the one `make release` printed.

The DMG is the **only** release artifact: the website download and the Homebrew
cask both consume it, so there is no second thing to keep in sync.

---

## Why the build does what it does

These are the parts that look like busywork and are not.

**Vendored dylibs.** Tusk links Homebrew's `libpq`, which links `openssl@3` and
`krb5`, which link more — all by absolute `/opt/homebrew/...` paths.
`packaging/bundle-dylibs.sh` walks that tree recursively, copies all 8 libraries
into `Contents/Frameworks`, and rewrites the load commands. Skip this and the app
launches perfectly on your Mac and dies instantly on everyone else's.
`make verify-bundle` fails the build if any Homebrew path survives.

**Signing order is inside-out.** Dylibs first, then the embedded CLI, then the app
bundle. `codesign` seals whatever it finds, so signing the bundle first would seal
unsigned libraries and fail notarization. (Do not reach for `--deep`; Apple
explicitly advises against it for distribution.)

**Signing happens after path rewriting.** `install_name_tool` invalidates a code
signature, and on Apple Silicon an invalid signature is *fatal* — dyld refuses to
load the image at all. Any signature applied before the rewrite is destroyed by
it, so real signing is the last step.

**The CLI is named `tuskcli` inside the bundle.** macOS filesystems are
case-insensitive: `Contents/MacOS/tusk` and `Contents/MacOS/Tusk` are the same
file, so shipping the CLI as `tusk` silently overwrites the GUI binary. The name
`tusk` is carried by the symlink that `make install` and the cask put on `PATH`.
The `bundle` target asserts both binaries survive at their expected sizes.

**Entitlements are deliberately empty.** Tusk is not sandboxed (it ships outside
the App Store), and it needs no hardened-runtime exceptions. In particular it does
*not* set `disable-library-validation` — the vendored dylibs carry the same
Developer ID as the app, so validation passes. Adding that entitlement would let
any library be injected into Tusk.

---

## Known limitation: Apple Silicon only

The app is **arm64-only**. Making it universal is not just a compiler flag: it
needs x86_64 builds of all 8 vendored dylibs, which Homebrew on Apple Silicon does
not provide. Doing it properly means either building libpq/openssl/krb5 from
source for both architectures, or pulling the x86_64 bottles and `lipo`-ing them
together. Until then, Intel Macs are unsupported.
