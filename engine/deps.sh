#!/bin/bash
# Installs build dependencies (a few minutes, no sudo):
#  - host tools via arm64 Homebrew: mingw-w64 cross compiler, bison, flex, ccache,
#    plus gnutls/freetype/sdl2-compat for their (architecture-neutral) headers
#  - x86_64 runtime libraries (gnutls, freetype, SDL2 and their deps) taken prebuilt
#    from Gcenx's open-source macOS Wine build (MacPorts-built, @loader_path-relative)
#  - MoltenVK from Khronos' universal prebuilt release
source "$(dirname "$0")/common.sh"

/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta 2 is required: softwareupdate --install-rosetta --agree-to-license"
command -v brew >/dev/null || die "Homebrew (arm64) is required: https://brew.sh"

log "Host build tools and headers"
brew install mingw-w64 bison flex ccache gnutls freetype sdl2-compat

GCENX_V=11.18
GCENX_SHA=b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127
TARBALL="$RMG_CACHE/wine-staging-$GCENX_V-osx64.tar.xz"
download "https://github.com/Gcenx/macOS_Wine_builds/releases/download/$GCENX_V/wine-staging-$GCENX_V-osx64.tar.xz" \
    "$TARBALL" "$GCENX_SHA"
log "Extracting prebuilt x86_64 libraries -> $X86LIBS"
rm -rf "$X86LIBS" "$RMG_CACHE/unpack-libs"; mkdir -p "$RMG_CACHE/unpack-libs"
tar -xJf "$TARBALL" -C "$RMG_CACHE/unpack-libs" '*/Contents/Resources/wine/lib/*.dylib'
mv "$RMG_CACHE/unpack-libs/"*/Contents/Resources/wine/lib "$X86LIBS"
rm -rf "$RMG_CACHE/unpack-libs"
for l in libgnutls.30.dylib libfreetype.6.dylib libSDL2-2.0.0.dylib; do
    [[ -f "$X86LIBS/$l" ]] || die "$l missing from prebuilt libraries"
done

# MoltenVK (Vulkan -> Metal) from Khronos' universal prebuilt release.
MVK_VERSION=v1.4.2
MVK_TAR="$RMG_CACHE/MoltenVK-macos-$MVK_VERSION.tar"
download "https://github.com/KhronosGroup/MoltenVK/releases/download/$MVK_VERSION/MoltenVK-macos.tar" \
    "$MVK_TAR" f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e
rm -rf "$RMG_CACHE/moltenvk"; mkdir -p "$RMG_CACHE/moltenvk"
tar -xf "$MVK_TAR" -C "$RMG_CACHE/moltenvk" --strip-components 2
log "Dependencies ready."
