#!/bin/bash
# RunMyGames installer: play Windows Steam games on Apple Silicon Macs.
#
#   curl -fsSL https://raw.githubusercontent.com/Rani367/runmygames/main/install.sh | bash
#
# Installs RunMyGames.app (to /Applications, or ~/Applications if that is not writable), the
# `rmg` command (~/.local/bin/rmg) and the game engine. Run it again to update.
#
# Options (environment variables):
#   RMG_VERSION=v1.2.3        install that release instead of the latest
#   RMG_INSTALL_FROM=<path>   install a local RunMyGames.app or release .zip (no download)
#   RMG_APP_DIR=<dir>         install the app into <dir> instead of /Applications
#   RMG_ENGINE_FROM=<path>    install the engine from a downloaded rmg-engine-*.tar.xz
#   RMG_SKIP_ENGINE=1         do not install or update the engine
#   RMG_NO_OPEN=1             do not open the app at the end
#   GITHUB_TOKEN=<token>      for a private repository or API rate limits
#
# Downloads by curl carry no quarantine flag, so macOS runs the app without Gatekeeper
# prompts even though it is not notarized; every download is checked against a SHA-256.

# Everything is inside main(), so a partially downloaded script never runs half-way.
main() {
    set -euo pipefail
    local repo="Rani367/runmygames"
    local bold="" dim="" red="" reset=""
    if [[ -t 1 ]]; then bold=$'\033[1m' dim=$'\033[2m' red=$'\033[31m' reset=$'\033[0m'; fi
    say() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
    die() { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

    # ------------------------------------------------------------ requirements
    [[ "$(uname -s)" == Darwin ]] || die "RunMyGames runs on macOS only."
    [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == 1 ]] ||
        die "RunMyGames needs a Mac with Apple silicon (M1 or newer)."
    local macos; macos="$(sw_vers -productVersion)"
    (( ${macos%%.*} >= 14 )) || die "RunMyGames needs macOS 14 Sonoma or newer (this Mac has $macos)."
    if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        say "Installing Rosetta 2 (Apple's translator for Intel code). macOS may ask for your password."
        # stdin is this script when piped from curl; read the password from the terminal.
        # shellcheck disable=SC2024
        sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license </dev/tty ||
            die "Rosetta 2 could not be installed. Run: softwareupdate --install-rosetta --agree-to-license"
    fi

    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/rmg-install.XXXXXX")"
    # Expanded now: the trap fires after main() returns, when $tmp is out of scope.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    # ------------------------------------------------------------ get the app
    local src="${RMG_INSTALL_FROM:-}" app_src
    if [[ -z "$src" ]]; then
        local auth=() api="https://api.github.com/repos/$repo/releases"
        [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
        local url="$api/latest"
        [[ -n "${RMG_VERSION:-}" ]] && url="$api/tags/${RMG_VERSION}"
        curl -fsSL ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" "$url" -o "$tmp/release.json" ||
            die "Could not find a RunMyGames release on GitHub ($url)."
        local tag; tag="$(plutil -extract tag_name raw -o - "$tmp/release.json")"
        say "Downloading RunMyGames ${tag#v}"
        # Assets are fetched through the API so the same code works for private repositories.
        local i=0 name zip_api="" sha_api=""
        while name="$(plutil -extract "assets.$i.name" raw -o - "$tmp/release.json" 2>/dev/null)"; do
            case "$name" in
                RunMyGames-*.zip) zip_api="$(plutil -extract "assets.$i.url" raw -o - "$tmp/release.json")"; src="$tmp/$name" ;;
                RunMyGames-*.zip.sha256) sha_api="$(plutil -extract "assets.$i.url" raw -o - "$tmp/release.json")" ;;
            esac
            i=$((i + 1))
        done
        [[ -n "$zip_api" && -n "$sha_api" ]] || die "Release $tag has no RunMyGames zip and checksum."
        curl -fL --progress-bar ${auth[@]+"${auth[@]}"} -H "Accept: application/octet-stream" "$zip_api" -o "$src"
        curl -fsSL ${auth[@]+"${auth[@]}"} -H "Accept: application/octet-stream" "$sha_api" -o "$src.sha256"
    fi

    if [[ -d "$src" ]]; then
        app_src="$src"
    else
        [[ -f "$src" ]] || die "$src does not exist."
        if [[ -f "$src.sha256" ]]; then
            local want got
            want="$(cut -d' ' -f1 <"$src.sha256")"
            got="$(shasum -a 256 "$src" | cut -d' ' -f1)"
            [[ "$want" == "$got" ]] || die "Checksum mismatch for $(basename "$src"); the download is damaged. Try again."
        elif [[ -z "${RMG_INSTALL_FROM:-}" ]]; then
            die "No checksum for $(basename "$src")."
        fi
        ditto -x -k "$src" "$tmp/unpacked"
        app_src="$tmp/unpacked/RunMyGames.app"
    fi
    [[ -x "$app_src/Contents/MacOS/rmg" ]] || die "$app_src is not a RunMyGames app."

    # ------------------------------------------------------------ install the app
    local dest_dir="${RMG_APP_DIR:-/Applications}"
    [[ -n "${RMG_APP_DIR:-}" || -w "$dest_dir" ]] || dest_dir="$HOME/Applications"
    mkdir -p "$dest_dir"
    local app="$dest_dir/RunMyGames.app"
    if pgrep -xq RunMyGames; then
        say "Quitting the running RunMyGames app"
        osascript -e 'quit app "RunMyGames"' >/dev/null 2>&1 || pkill -x RunMyGames || true
        sleep 1
    fi
    say "Installing $app"
    rm -rf "$app.new"
    ditto "$app_src" "$app.new"
    xattr -dr com.apple.quarantine "$app.new" 2>/dev/null || true
    rm -rf "$app"
    mv "$app.new" "$app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true

    # ------------------------------------------------------------ CLI
    local bin="$HOME/.local/bin"
    mkdir -p "$bin"
    ln -sf "$app/Contents/MacOS/rmg" "$bin/rmg"
    say "Installed the rmg command: $bin/rmg"
    # The $HOME/$PATH in the hint are meant literally: it is a line for the user to paste.
    # shellcheck disable=SC2016
    case ":$PATH:" in
        *":$bin:"*) ;;
        *) printf '   %sAdd it to your PATH:%s echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc\n' "$dim" "$reset" ;;
    esac

    # ------------------------------------------------------------ engine
    local rmg="$app/Contents/MacOS/rmg"
    if [[ "${RMG_SKIP_ENGINE:-}" != 1 ]]; then
        if [[ -n "${RMG_ENGINE_FROM:-}" ]]; then
            "$rmg" engine install --from "$RMG_ENGINE_FROM"
        elif "$rmg" engine status 2>/dev/null | grep -q "Up to date"; then
            say "The game engine is up to date"
        else
            say "Downloading the game engine (about 100 MB)"
            "$rmg" engine install || printf '%sThe engine download failed; RunMyGames.app can retry it.%s\n' "$red" "$reset"
        fi
    fi

    say "${bold}RunMyGames $("$rmg" --version) is installed.${reset}"
    echo "   Open RunMyGames from your Applications folder to finish setup, or run: rmg setup"
    echo "   To uninstall later: rmg uninstall"
    if [[ "${RMG_NO_OPEN:-}" != 1 ]]; then open "$app"; fi
}

main "$@"
