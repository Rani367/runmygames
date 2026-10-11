#!/bin/bash
# One-shot engine setup used by the app's "Build Engine" button and `make engine`:
# dependencies -> CrossOver-source Wine (prebuilt fallback on failure) -> DXMT.
source "$(dirname "$0")/common.sh"
E="$(dirname "$0")"

bash "$E/fetch-dxmt.sh"
bash "$E/deps.sh"
if ! bash "$E/build-wine.sh"; then
    warn "CrossOver-source build failed; installing the prebuilt fallback engine instead."
    bash "$E/fallback-prebuilt.sh"
fi
log "Done. Next: install Steam (RunMyGames.app or \`rmg setup\`)."
