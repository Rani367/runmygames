#!/bin/bash
# Packages a built engine ($ENGINE_DIR, i.e. engines/wine-cx-<version>) as the prebuilt
# download that RunMyGames installs, and points engine/manifest.json at it.
#
#   engine/package-engine.sh                      # build string from engine/manifest.json
#   ENGINE_BUILD=26.3.0-2 engine/package-engine.sh
#
# Output: dist/rmg-engine-<name>-<build-suffix>.tar.xz (+ .sha256). Upload it to the GitHub
# release "engine-<build>" (`make release-engine` prints the command).
source "$(dirname "$0")/common.sh"

MANIFEST="$RMG_REPO/engine/manifest.json"
field() { plutil -extract "$1" raw -o - "$MANIFEST"; }
ENGINE_BUILD="${ENGINE_BUILD:-$(field engine.build)}"
NAME="$(basename "$ENGINE_DIR")"
OUT_DIR="$RMG_REPO/dist"
ARCHIVE="rmg-engine-$NAME-${ENGINE_BUILD#"$CX_VERSION"-}.tar.xz"
URL="https://github.com/Rani367/runmygames/releases/download/engine-$ENGINE_BUILD/$ARCHIVE"

[[ -x "$ENGINE_DIR/bin/wine" ]] || die "no engine at $ENGINE_DIR (build it with engine/build-wine.sh)"
[[ -d "$ENGINE_DIR/RunMyGames Engine.app" ]] || die "engine is not wrapped; run engine/wrap-engine.sh"

# ---------------------------------------------------------------- relocation checks
# Users install under their own home folder, so nothing may point into this build machine.
log "Checking that $NAME is relocatable"
if find "$ENGINE_DIR" -type l -exec readlink {} \; | grep -q '^/'; then
    die "absolute symlinks inside the engine"
fi
bad="$(find "$ENGINE_DIR" -type f \( -name '*.dylib' -o -name '*.so' -o -perm +111 \) -print0 \
    | xargs -0 otool -L 2>/dev/null | grep -E '^[[:space:]]+/(Users|opt/homebrew|usr/local)/' | sort -u || true)"
[[ -z "$bad" ]] || die "libraries linked by absolute build paths:"$'\n'"$bad"
# Wine keeps its configure-time directories as a fallback for when it cannot locate itself,
# and assert() keeps source paths; neither is used when the engine runs from elsewhere
# (engine install tests prove that).
mentions="$(grep -rlF "$HOME" "$ENGINE_DIR" 2>/dev/null || true)"
if [[ -n "$mentions" ]]; then
    warn "$(wc -l <<<"$mentions" | tr -d ' ') files mention $HOME (configure-time fallbacks and assert paths)"
fi

# ---------------------------------------------------------------- stage
STAGE_ROOT="$RMG_CACHE/package"
rm -rf "$STAGE_ROOT"; mkdir -p "$STAGE_ROOT"
log "Staging $NAME ($ENGINE_BUILD)"
ditto "$ENGINE_DIR" "$STAGE_ROOT/$NAME"
rm -f "$STAGE_ROOT/$NAME/RMG_ENGINE_BUILD"   # written by the installer
cp "$RMG_REPO/THIRD_PARTY_NOTICES.md" "$STAGE_ROOT/$NAME/"
if [[ -f "$RMG_CACHE/sources/wine/COPYING.LIB" ]]; then
    cp "$RMG_CACHE/sources/wine/COPYING.LIB" "$STAGE_ROOT/$NAME/COPYING.LIB"
fi
cat > "$STAGE_ROOT/$NAME/SOURCE.md" <<EOF
# RunMyGames engine $ENGINE_BUILD

Wine from CodeWeavers' CrossOver $CX_VERSION source release (LGPL-2.1-or-later), built by
RunMyGames' engine/build-wine.sh with the patches in engine/patches/.

- Wine source: $CX_URL
  sha256 $CX_SHA256
- Build scripts and patches: https://github.com/Rani367/runmygames/tree/main/engine
- Bundled libraries and their licenses: THIRD_PARTY_NOTICES.md

To rebuild it yourself: \`rmg engine build\` (or \`make engine\` in a checkout).
EOF

# ---------------------------------------------------------------- archive
mkdir -p "$OUT_DIR"
log "Compressing (a few minutes)"
if command -v xz >/dev/null; then
    tar -C "$STAGE_ROOT" -cf - "$NAME" | xz -T0 -6 > "$OUT_DIR/$ARCHIVE"
else
    tar -C "$STAGE_ROOT" -cJf "$OUT_DIR/$ARCHIVE" "$NAME"
fi
rm -rf "$STAGE_ROOT"
SHA="$(shasum -a 256 "$OUT_DIR/$ARCHIVE" | cut -d' ' -f1)"
SIZE="$(stat -f %z "$OUT_DIR/$ARCHIVE")"
echo "$SHA  $ARCHIVE" > "$OUT_DIR/$ARCHIVE.sha256"

# ---------------------------------------------------------------- manifest
# Read before rewriting: the redirect below truncates the file.
DXMT_VERSION="$(field dxmt.version)" DXMT_URL="$(field dxmt.url)" DXMT_SHA="$(field dxmt.sha256)"
cat > "$MANIFEST" <<EOF
{
  "engine": {
    "name": "$NAME",
    "build": "$ENGINE_BUILD",
    "url": "$URL",
    "sha256": "$SHA",
    "size": $SIZE
  },
  "dxmt": {
    "version": "$DXMT_VERSION",
    "url": "$DXMT_URL",
    "sha256": "$DXMT_SHA"
  }
}
EOF

log "Packaged $OUT_DIR/$ARCHIVE ($((SIZE / 1048576)) MB, sha256 $SHA)"
log "engine/manifest.json updated. Publish with:"
echo "  gh release create engine-$ENGINE_BUILD '$OUT_DIR/$ARCHIVE' '$OUT_DIR/$ARCHIVE.sha256' \\"
echo "     --prerelease --title 'Engine $ENGINE_BUILD' --notes 'Prebuilt engine for RunMyGames. sha256 $SHA'"
