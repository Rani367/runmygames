# Contributing to RunMyGames

Thanks for helping! Bug reports, game compatibility reports and pull requests are all welcome.
For anything bigger than a small fix, opening an issue first to talk it through saves everyone time.

## Development setup

You need:

- An Apple Silicon Mac on macOS 14 or newer, with Rosetta 2
- Xcode, or just the Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh), then:

```sh
brew install mingw-w64 shellcheck
```

`mingw-w64` cross-compiles the two small Windows programs in `shim/`; `shellcheck` lints the shell scripts.

## Repo layout

| Path | What |
|---|---|
| `engine/` | Bash scripts that build or install the Wine engine, fetch DXMT and import D3DMetal, the Wine patch, and `manifest.json` (pinned engine + DXMT downloads) |
| `shim/` | `rmgshim.c` (Steam launches every game through it) and `webhelper.c` (the `steamwebhelper.exe` wrapper). Plain C, built with mingw |
| `app/Sources/RMGCore` | Everything shared: Steam/VDF parsing, PE scanning, renderer policy, launching, settings, engine installer |
| `app/Sources/rmg` | The `rmg` command-line tool |
| `app/Sources/RunMyGames` | The SwiftUI app |
| `app/Tests/RMGCoreTests` | Unit tests |
| `compat/games.json` | Known-good settings per Steam app id |

## Building and testing

```sh
make app                    # build/RunMyGames.app (also builds the shims)
make test                   # unit tests
make lint                   # what CI runs: warnings-as-errors build, shellcheck, shim syntax, compat/games.json check
make install SKIP_ENGINE=1  # install your build to /Applications without downloading the engine again
```

Please run `make lint` and `make test` before opening a pull request.

### Running a debug build without touching your real setup

Point the app at a throwaway home so your real prefix, settings and games stay untouched:

```sh
make shim                                   # the dev checkout uses build/rmgshim.exe
cd app && swift build
RMG_HOME=/tmp/rmg-test .build/debug/RunMyGames
RMG_HOME=/tmp/rmg-test .build/debug/rmg doctor
```

Environment variables that help during development:

| Variable | Effect |
|---|---|
| `RMG_HOME` | Data directory (engine, prefix, settings). Default: `~/Library/Application Support/RunMyGames` |
| `RMG_RESOURCES` | Where to find `compat/`, `engine/` and the shims. Auto-detected from the `.app` or the repo checkout; override it to test against e.g. `build/RunMyGames.app/Contents/Resources` |
| `RMG_ENGINE_MANIFEST` | Use a different `manifest.json`, e.g. to test an engine tarball before publishing it |
| `RMG_WINEDEBUG` | Passed to Wine as `WINEDEBUG` (default `-all`), e.g. `RMG_WINEDEBUG=+loaddll,+seh` |
| `RMG_SNAPSHOT=/tmp/shot.png` | Renders the app window to a PNG a few seconds after launch (`RMG_SNAPSHOT_DELAY`, default 4). Add `RMG_SNAPSHOT_QUIT=1` to quit afterwards |

For example, to check a UI change without screen recording:

```sh
RMG_HOME=/tmp/rmg-test RMG_SNAPSHOT=/tmp/shot.png RMG_SNAPSHOT_QUIT=1 .build/debug/RunMyGames
```

## Adding a game to compat/games.json

Most games need no entry: RunMyGames scans each game's executable and picks a renderer on its own.
**Only add an entry after confirming the setting actually matters**, i.e. the game breaks or runs
clearly worse with the automatic choice and works with yours. Always include a `notes` line saying why,
so the next person knows whether the entry is still needed.

Entries are keyed by Steam app id (the number in the store URL, or the first column of `rmg games`):

```json
"123456": {
  "name": "Example Game",
  "renderer": "dxmt",
  "args": "-skipintro",
  "env": { "EXAMPLE_VAR": "1" },
  "notes": "Ships a DirectX 12 exe but D3DMetal crashes on load; the DX11 path via DXMT works. -skipintro avoids a black-screen intro video."
}
```

- `renderer`: `d3dmetal`, `dxmt` or `wined3d`
- `args`, `env`, `notes`: optional
- Test it with `rmg set <appid> renderer=...` first, then add the entry and run `make lint`, which validates the file.

## Code style

- Match the surrounding code. No new dependencies without discussing it first.
- Comments explain *why*, not what. If something looks odd but is deliberate (a Wine quirk, a Steam race),
  say so next to it.
- **Never run `Process` / `waitUntilExit()` on the main thread in SwiftUI code.** `waitUntilExit` spins the
  run loop, which re-enters SwiftUI view updates while the app is mid-update. This caused a real crash.
  Run blocking work off the main thread (see `Model.swift`) and hop back to update the UI.
- Shell scripts must pass `shellcheck -x`; the shims must build with `-Wall -Werror`.

## Releasing

### App releases

1. Bump `VERSION` and run `make version` (regenerates `app/Sources/RMGCore/Version.swift`; CI checks they match).
2. Move the `## [Unreleased]` notes in `CHANGELOG.md` into a new `## [X.Y.Z] - YYYY-MM-DD` section.
3. Commit, then tag and push:

   ```sh
   git tag vX.Y.Z && git push origin main vX.Y.Z
   ```

The `release.yml` workflow checks the tag matches `VERSION`, builds the zip and its `.sha256`, and
publishes the GitHub release with that version's CHANGELOG section as notes. `install.sh` and the app's
update check pick it up from there.

### Engine releases

The prebuilt engine lives on its own `engine-<build>` release, separate from app releases. The app finds
it through `engine/manifest.json`, which ships inside the app, so a new engine reaches users with the next
app release.

1. Build and install the engine on your Mac (`make engine`) and test it with a few games.
2. Bump `engine.build` in `engine/manifest.json`, e.g. `26.3.0-1` -> `26.3.0-2`.
3. Run `make release-engine`. It packages the engine installed on your Mac into
   `dist/rmg-engine-….tar.xz` (+ `.sha256`), writes the new url, sha256 and size into `engine/manifest.json`,
   and prints them along with the upload command. (`ENGINE_BUILD=26.3.0-2 make release-engine` overrides
   the build string instead of reading it from the manifest.)
4. Upload it as a prerelease, so the app's update check (which looks at the latest release) ignores it:

   ```sh
   gh release create engine-26.3.0-2 dist/rmg-engine-*.tar.xz dist/rmg-engine-*.tar.xz.sha256 \
     --prerelease --title "Engine 26.3.0-2" --notes "Engine asset referenced by engine/manifest.json."
   ```

5. Test the download into a throwaway home, then commit the manifest:

   ```sh
   RMG_HOME=/tmp/rmg-test RMG_ENGINE_MANIFEST="$PWD/engine/manifest.json" rmg engine install
   ```

There is also a manual `engine.yml` workflow that builds the engine on a GitHub runner. It takes 60-90
minutes and macOS minutes are billed at 10x on private repos, so use the local route until the repo is public.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
