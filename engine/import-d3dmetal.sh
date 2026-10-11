#!/bin/bash
# Imports Apple's D3DMetal (DirectX 11/12 -> Metal) from the Game Porting Toolkit.
# D3DMetal is free but Apple-licensed and closed source, so it is never shipped
# with RunMyGames: download the GPTK .dmg yourself (free Apple ID) from
#   https://developer.apple.com/games/game-porting-toolkit/
# then run:  engine/import-d3dmetal.sh ~/Downloads/Game_Porting_Toolkit_3.0.dmg
source "$(dirname "$0")/common.sh"

DMG="${1:-}"
if [[ -z "$DMG" ]]; then
    DMG="$(ls -t "$HOME"/Downloads/*[Pp]orting*[Tt]oolkit*.dmg 2>/dev/null | head -1 || true)"
fi
[[ -f "$DMG" ]] || die "usage: $0 path/to/Game_Porting_Toolkit.dmg (download from developer.apple.com/games)"

MOUNTS=()
cleanup() { for m in "${MOUNTS[@]}"; do hdiutil detach -quiet "$m" 2>/dev/null || true; done; }
trap cleanup EXIT

attach() {  # attach DMG -> echo mountpoint
    local mp; mp="$(mktemp -d "${TMPDIR:-/tmp}/rmg-gptk.XXXX")"
    hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mp" "$1" >/dev/null
    MOUNTS+=("$mp"); echo "$mp"
}

# GPTK ships a nested "Evaluation environment" dmg; search up to two levels deep.
find_redist() {
    local root="$1" lib
    lib="$(find "$root" -maxdepth 4 -type d -path '*redist/lib' 2>/dev/null | head -1)"
    if [[ -n "$lib" ]]; then echo "$lib"; return 0; fi
    local inner
    while IFS= read -r inner; do
        lib="$(find_redist "$(attach "$inner")")" && { echo "$lib"; return 0; }
    done < <(find "$root" -maxdepth 2 -name '*.dmg' 2>/dev/null)
    return 1
}

log "Mounting $(basename "$DMG")"
REDIST="$(find_redist "$(attach "$DMG")")" || die "no redist/lib found inside $DMG"
[[ -d "$REDIST/external/D3DMetal.framework" ]] || die "D3DMetal.framework missing in $REDIST"

DEST="$RENDERERS_DIR/d3dmetal"
rm -rf "$DEST"; mkdir -p "$DEST"
# Keep Apple's layout: wine/x86_64-unix/*.so are symlinks to ../../external/libd3dshared.dylib.
# wine/ holds the PE + unix halves of d3d11/d3d12/dxgi (+ nvapi/nvngx for DLSS -> MetalFX)
# and is what gets prepended to the DLL search path.
cp -R "$REDIST/external" "$DEST/external"
cp -R "$REDIST/wine" "$DEST/wine"
[[ -e "$DEST/wine/x86_64-unix/d3d12.so" ]] || die "unexpected GPTK layout (wine/x86_64-unix/d3d12.so missing)"
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
      "$DEST/external/D3DMetal.framework/Resources/Info.plist" 2>/dev/null || echo unknown)"
echo "$VER" > "$DEST/VERSION"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
log "D3DMetal $VER -> $DEST"
