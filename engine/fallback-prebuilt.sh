#!/bin/bash
# Fallback if the CrossOver-source build fails: Gcenx's prebuilt upstream Wine (wine-staging).
# Limitations compared with the source build: no msync, no D3DMetal hooks, and no
# per-game renderer switching (WINEDLLPATH_PREPEND), so DXMT is installed engine-wide.
source "$(dirname "$0")/common.sh"

V=11.18
SHA=b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127
TARBALL="$RMG_CACHE/wine-staging-$V-osx64.tar.xz"
download "https://github.com/Gcenx/macOS_Wine_builds/releases/download/$V/wine-staging-$V-osx64.tar.xz" "$TARBALL" "$SHA"

DEST="$RMG_HOME/engines/wine-staging-$V"
rm -rf "$DEST" "$RMG_CACHE/unpack-prebuilt"; mkdir -p "$RMG_CACHE/unpack-prebuilt"
tar -xJf "$TARBALL" -C "$RMG_CACHE/unpack-prebuilt"
SRC="$(find "$RMG_CACHE/unpack-prebuilt" -maxdepth 4 -type d -path '*Contents/Resources/wine' | head -1)"
[[ -n "$SRC" ]] || die "unexpected archive layout"
mkdir -p "$(dirname "$DEST")"; mv "$SRC" "$DEST"; rm -rf "$RMG_CACHE/unpack-prebuilt"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "staging-$V (prebuilt fallback)" > "$DEST/RMG_ENGINE_VERSION"

if [[ -d "$RENDERERS_DIR/dxmt" ]]; then
    log "Installing DXMT engine-wide (no per-game switching in fallback mode)"
    for a in x86_64-windows i386-windows x86_64-unix; do
        cp "$RENDERERS_DIR/dxmt/$a/"* "$DEST/lib/wine/$a/" 2>/dev/null || true
    done
fi
ENGINE_DIR="$DEST" "$RMG_REPO/engine/wrap-engine.sh"
log "Fallback engine ready: $DEST"
