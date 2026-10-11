#!/bin/bash
# DXMT: open-source Direct3D 10/11 -> Metal translation (3Shain/dxmt).
# Installed as its own renderer tree; selected per game via WINEDLLPATH_PREPEND.
source "$(dirname "$0")/common.sh"

DXMT_VERSION="${DXMT_VERSION:-v0.80}"
DXMT_SHA256="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
TARBALL="$RMG_CACHE/dxmt-$DXMT_VERSION-builtin.tar.gz"
download "https://github.com/3Shain/dxmt/releases/download/$DXMT_VERSION/dxmt-$DXMT_VERSION-builtin.tar.gz" \
    "$TARBALL" "$DXMT_SHA256"

DEST="$RENDERERS_DIR/dxmt"
rm -rf "$DEST"; mkdir -p "$DEST"
tar -xzf "$TARBALL" -C "$DEST" --strip-components 1
echo "$DXMT_VERSION" > "$DEST/VERSION"
log "DXMT $DXMT_VERSION -> $DEST"
