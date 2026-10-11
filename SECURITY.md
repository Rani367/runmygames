# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately instead:

1. Go to the repo's **Security** tab and click **Report a vulnerability**
   (<https://github.com/Rani367/runmygames/security/advisories/new>).
2. Describe the problem, how to reproduce it, and what an attacker could do with it.

You'll get a reply as soon as possible, usually within a few days. Once a fix is released, the advisory
is published and you're credited unless you'd rather not be.

Only the latest release gets security fixes.

## Scope and things to know

- **Wine is not a sandbox.** Games, Steam and anything else you run in the prefix run with your normal
  macOS user privileges and can read and write your files, like any Mac app you install. Only run Windows
  software you trust. Issues that boil down to "a Windows program can access my files" are expected
  behaviour, not vulnerabilities.
- **Downloads are pinned by SHA-256.** The prebuilt Wine engine and DXMT are verified against the checksums
  in `engine/manifest.json` before they're installed; the engine build scripts verify their sources the same
  way. The release zip that `install.sh` downloads comes with a `.sha256` file that is checked too.
- **Two downloads are not pinned:** the Steam installer and the Microsoft Visual C++ redistributables come
  straight from Valve and Microsoft over HTTPS. Their contents change with every vendor update, so they
  can't be pinned to a fixed checksum.
- **Builds are ad-hoc signed**, not signed with an Apple Developer ID or notarized, so Gatekeeper can't vouch
  for them. Install from this repo's releases (or build from source) and nowhere else.

Things we'd especially like to hear about: a way to bypass checksum verification, the installer or updater
fetching code from somewhere unexpected, or RunMyGames itself (the app, `rmg`, or the shims) letting a
game or website do something it otherwise couldn't.
