# shellcheck shell=bash disable=SC2034
# Shared paths and helpers for the RunMyGames engine scripts.
set -euo pipefail

RMG_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RMG_HOME="${RMG_HOME:-$HOME/Library/Application Support/RunMyGames}"
# Build tree lives in Caches: no spaces in the path (autotools hates them) and safe to delete.
RMG_CACHE="${RMG_CACHE:-$HOME/Library/Caches/RunMyGames}"
X86LIBS="$RMG_CACHE/x86libs"   # prebuilt x86_64 dylibs (see deps.sh)

CX_VERSION="${CX_VERSION:-26.3.0}"
CX_SHA256="ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
CX_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VERSION.tar.gz"

ENGINE_NAME="wine-cx-$CX_VERSION"
ENGINE_DIR="${ENGINE_DIR:-$RMG_HOME/engines/$ENGINE_NAME}"
RENDERERS_DIR="$RMG_HOME/renderers"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }


# download URL DEST SHA256 — skips if DEST already matches.
download() {
    local url="$1" dest="$2" sha="$3"
    if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$sha" ]]; then return 0; fi
    log "Downloading $(basename "$dest")"
    curl -fL --retry 3 -o "$dest.part" "$url"
    local got; got="$(shasum -a 256 "$dest.part" | cut -d' ' -f1)"
    [[ "$got" == "$sha" ]] || die "checksum mismatch for $url (got $got)"
    mv "$dest.part" "$dest"
}

mkdir -p "$RMG_HOME" "$RMG_CACHE"
