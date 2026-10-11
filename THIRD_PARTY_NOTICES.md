# Third-party software

RunMyGames' own code (the app, the `rmg` CLI, `rmgshim.exe`, the webhelper wrapper and the
build scripts) is MIT-licensed; see `LICENSE`. The game engine it downloads is built from
other open-source projects under their own licenses, listed here. RunMyGames is not
affiliated with or endorsed by CodeWeavers, Valve, Apple, Khronos or Microsoft.

## Distributed in the prebuilt engine (`rmg-engine-*.tar.xz`)

| Component | License | Source |
|---|---|---|
| Wine, as modified by CodeWeavers for CrossOver 26.3 | LGPL-2.1-or-later | <https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz> (sha256 `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`), plus `engine/patches/` in this repository |
| MoltenVK 1.4.2 | Apache-2.0 | <https://github.com/KhronosGroup/MoltenVK> |
| GnuTLS, Nettle, GMP, libtasn1, libidn2, libunistring, libiconv, libintl | LGPL (2.1+ or 3+, per library) | via <https://github.com/Gcenx/macOS_Wine_builds> (MacPorts builds) |
| FreeType | FreeType License (FTL) | <https://freetype.org> |
| SDL2 | zlib | <https://libsdl.org> |
| libpng, zlib, bzip2, xz/liblzma, lz4, zstd, brotli, libffi, libxml2, libxslt, p11-kit, libpcap, ICU, libinotify | permissive (libpng, zlib, bzip2, 0BSD/public domain, BSD, MIT, Unicode) | via <https://github.com/Gcenx/macOS_Wine_builds> |

The engine archive contains `SOURCE.md` with these links. Under the LGPL you may replace
any of these libraries with your own build; `engine/build-wine.sh` rebuilds the whole engine
from the sources above.

## Downloaded from upstream at setup time

| Component | License | Source |
|---|---|---|
| DXMT (Direct3D 10/11 → Metal) | LGPL-2.1-or-later | <https://github.com/3Shain/dxmt> |
| Steam client | Valve's Steam Subscriber Agreement | <https://store.steampowered.com/about/> |
| Microsoft Visual C++ Redistributable | Microsoft Software License Terms | <https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist> |

## Not distributed

**D3DMetal** (part of Apple's Game Porting Toolkit) may not be redistributed. RunMyGames only
imports it from a Game Porting Toolkit disk image that you download from Apple yourself.
