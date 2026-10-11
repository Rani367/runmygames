# RunMyGames

Run your **Windows Steam games on Apple Silicon Macs** for free. It is assembled from the same open
components CrossOver ships, plus glue that makes it feel native:

| Layer | What | License |
|---|---|---|
| Wine engine | **CodeWeavers' CrossOver 26.3 Wine**, built from their [public LGPL source release](https://media.codeweavers.com/pub/crossover/source/) with msync, Mac driver and D3DMetal hooks | LGPL |
| DirectX 10/11 | [DXMT](https://github.com/3Shain/dxmt) (Metal) | MIT / LGPL |
| DirectX 11/12 | Apple **D3DMetal** from the Game Porting Toolkit (*optional*, you import it) | Apple (free) |
| DirectX ≤ 9 | WineD3D | LGPL |
| Vulkan | [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Apache 2 |
| Glue | RunMyGames app, `rmg` CLI, `rmgshim.exe` | this repo |

What the glue adds:

- **Automatic renderer per game.** The game's executable (and engine DLLs such as `UnityPlayer.dll`) is scanned for its
  DirectX imports, and the game gets D3DMetal, DXMT or WineD3D to match. A compatibility list can override this, and so can you.
  If the automatic choice crashes within seconds, the next launch tries the other renderer.
- **One-click launch.** Each game can get its own `.app` in `~/Applications/RunMyGames` with its real artwork, so it shows up in
  Launchpad, Spotlight and the Dock. Clicking it starts Steam silently in the background, launches the game, and
  closes Steam again a minute after you quit.
- **Mac-native behaviour.** Games run inside a "RunMyGames Engine" app bundle that is marked as a game, so
  **Game Mode** turns on and controllers are recognised. Option works as Alt and fonts are smoothed.
- **Per-game tweaks.** Metal performance HUD, MetalFX upscaling (DLSS → MetalFX), Retina mode, launch arguments and
  environment variables.

## How it works

```
Launchpad icon ──> rmg launch <appid> ──> Steam.exe -silent -applaunch <appid>
                                              │  (launch option injected by RunMyGames)
                                              ▼
                       C:\rmg\rmgshim.exe %command%
                       reads C:\rmg\games\<appid>.env (renderer, HUD, MetalFX…)
                                              │
                                              ▼
                       game.exe  ──>  DXMT | D3DMetal | WineD3D  ──>  Metal
```

Renderers are switched per game with one small Wine patch (`engine/patches/0001-winedllpath-prepend.patch`).
It adds `WINEDLLPATH_PREPEND`, which lets a renderer's `d3d11.dll`/`dxgi.dll`/`d3d12.dll` take priority over Wine's
builtins for that process only. CrossOver does this with a closed-source helper; here it is ~15 lines of C.

## Install

Requirements: an Apple Silicon Mac, macOS 14 or newer, Rosetta 2, Xcode (or the Command Line Tools) and Homebrew.

```sh
make install          # builds RunMyGames.app -> /Applications, CLI -> ~/.local/bin/rmg
make engine           # one-time: builds the Wine engine (~45 min the first time) + fetches DXMT
rmg setup             # creates the Windows prefix and installs Steam
rmg steam             # log in and install games
rmg launchers         # add every installed game to Launchpad
```

Or open **RunMyGames.app** and click through the setup screen.

### DirectX 12 games (optional, recommended)

1. Download **Game Porting Toolkit** from <https://developer.apple.com/games/game-porting-toolkit/> (free Apple ID).
2. `make d3dmetal DMG=~/Downloads/Game_Porting_Toolkit_3.0.dmg`, or use *Import D3DMetal…* in the app.

## Everyday use

```sh
rmg games                       # list installed games + chosen renderer
rmg launch 1091500              # play (or click the game's icon / double-click in the app)
rmg set 1091500 hud=on metalfx=on
rmg set 292030 renderer=d3dmetal args="-skipintro"
rmg config retina=on            # global settings
rmg doctor                      # health check
rmg kill                        # force-quit Steam + games
rmg wine winecfg                # run anything inside the prefix
```

Files:

| | |
|---|---|
| `~/Library/Application Support/RunMyGames/` | engine, renderers, prefix (`prefix/drive_c`…), settings |
| `~/Library/Logs/RunMyGames/` | Steam and setup logs |
| `prefix/drive_c/rmg/logs/shim.log` | what each game was launched with |
| `~/Library/Caches/RunMyGames/` | build tree; safe to delete after `make engine` |

## Limits

- Games with **kernel-level anti-cheat** (EAC/BattlEye in protected mode, Vanguard, Ricochet…) won't run. This is the
  same with CrossOver.
- Steam's own UI renders in software. Under Wine, Chromium's sandbox leaves the Steam window black, so RunMyGames
  replaces `steamwebhelper.exe` with a tiny wrapper (`shim/webhelper.c`) that starts Valve's helper with
  `--no-sandbox --disable-gpu --in-process-gpu`, the same switches CrossOver ends up with. The wrapper is re-applied
  automatically after Steam updates. Games are not affected.
- New games need Steam closed once so RunMyGames can add its launch option. Launching from a RunMyGames icon does this
  automatically: Steam restarts once for that game.
- Rosetta 2 is required. Apple has said Rosetta stays available for games after macOS 27.

## Development

```sh
make test     # unit tests (VDF, PE scanner, renderer policy, launch options)
make app      # build/RunMyGames.app
```

Layout: `engine/` (build scripts + Wine patch), `shim/` (Windows launcher), `app/` (Swift package: `RMGCore`,
`rmg`, `RunMyGames`), `compat/games.json` (known-good settings per app id; contributions welcome).
